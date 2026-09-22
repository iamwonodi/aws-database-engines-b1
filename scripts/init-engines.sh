#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# INITIALISE A CLONE OF THIS BLUEPRINT FOR ONE PROJECT
#
# Values that differ per project ship as the marker CHANGE_ME, and CI refuses to
# plan while any remain. This sets them, prepares GitHub to guard the
# deployment, and prints what core needs to generate this repository's role.
# Safe to re-run: it rewrites only the values it owns and PUTs GitHub
# Environments idempotently.
#
#   Files   infrastructure/development/terraform.tfvars   project_name, aws_region
#           infrastructure/development/backend.tf         state bucket and region
#
#   GitHub  Environment development        guards the deploy. Deployments only from main.
#           Environment development-plan   guards plans on pull requests.
#           Reviewers (if given) are required on BOTH: this repository can change
#           any inbound rule on the isolated security group, where the databases
#           live. Each gets the AWS_REGION variable. TF_AWS_ROLE_ARN is set later
#           by scripts/fetch-role-arn.sh, once core has created the role.
#
# Usage:
#   scripts/init-engines.sh --project NAME --region REGION \
#       [--reviewers login1,login2] [--repo OWNER/REPO] [--skip-github] [--dry-run]
#
#   --project   the project core was set up with (bucket names derive from it)
#   --dry-run   show what would change; write and call nothing
#
# Needs: bash, sed, jq; gh (authenticated) unless --skip-github or --dry-run.
# ==============================================================================

REPO_ROOT="${INIT_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

PROJECT="" REGION="" REVIEWERS="" REPO=""
SKIP_GITHUB=false
DRY_RUN=false

usage() { sed -n '/^# Usage:/,/^# Needs:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | head -n -1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)     PROJECT="${2:-}"; shift 2 ;;
    --region)      REGION="${2:-}"; shift 2 ;;
    --reviewers)   REVIEWERS="${2:-}"; shift 2 ;;
    --repo)        REPO="${2:-}"; shift 2 ;;
    --skip-github) SKIP_GITHUB=true; shift ;;
    --dry-run)     DRY_RUN=true; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "ERROR: unknown argument '$1'." >&2; usage >&2; exit 1 ;;
  esac
done

errors=()
[[ "${PROJECT}" =~ ^[a-z][a-z0-9-]{1,14}[a-z0-9]$ ]] || errors+=("--project must be 3-16 lowercase letters, digits or hyphens, starting with a letter.")
[[ "${REGION}" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]$ ]] || errors+=("--region must look like af-south-1.")
if [[ -n "${REPO}" && ! "${REPO}" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]]; then errors+=("--repo must be OWNER/REPOSITORY."); fi
if [[ -n "${REVIEWERS}" && ! "${REVIEWERS}" =~ ^[A-Za-z0-9-]+(,[A-Za-z0-9-]+)*$ ]]; then errors+=("--reviewers must be comma-separated GitHub logins."); fi

if [[ ${#errors[@]} -gt 0 ]]; then
  printf 'ERROR: %s\n' "${errors[@]}" >&2
  exit 1
fi

for command in sed jq; do
  command -v "${command}" >/dev/null 2>&1 || { echo "ERROR: required command not found: ${command}" >&2; exit 1; }
done

if [[ "${SKIP_GITHUB}" != "true" && "${DRY_RUN}" != "true" ]]; then
  command -v gh >/dev/null 2>&1 || { echo "ERROR: gh is required (or pass --skip-github)." >&2; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "ERROR: gh is not authenticated. Run: gh auth login" >&2; exit 1; }
fi

if [[ -z "${REPO}" && "${SKIP_GITHUB}" != "true" ]]; then
  REMOTE_URL="$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null || true)"
  [[ -n "${REMOTE_URL}" ]] || { echo "ERROR: no origin remote; pass --repo OWNER/REPOSITORY." >&2; exit 1; }
  REPO="$(sed -E 's#^(https?://[^/]+/|git@[^:]+:|ssh://[^/]+/)##; s#\.git$##; s#/$##' <<< "${REMOTE_URL}")"
fi

DIR="${REPO_ROOT}/infrastructure/development"

# ------------------------------------------------------------------------------
# Files
# ------------------------------------------------------------------------------

# Replaces the quoted value on the line that sets KEY, keeping alignment and any
# trailing comment. Writes through a temporary file (sed -i differs between GNU
# and BSD) and fails loudly if the line is missing.
set_string() {
  local file="$1" key="$2" value="$3" tmp d=$'\001'
  grep -qE "^[[:space:]]*${key}[[:space:]]*=" "${file}" || { echo "ERROR: ${file} has no '${key} =' line to set." >&2; exit 1; }
  tmp="$(mktemp)"
  sed -E "s${d}^([[:space:]]*${key}[[:space:]]*=[[:space:]]*)\"[^\"]*\"${d}\\1\"${value}\"${d}" "${file}" > "${tmp}"
  cat "${tmp}" > "${file}"
  rm -f "${tmp}"
}

echo "Files"
[[ -f "${DIR}/terraform.tfvars" && -f "${DIR}/backend.tf" ]] || { echo "ERROR: ${DIR} is missing terraform.tfvars or backend.tf." >&2; exit 1; }
echo "  development: project=${PROJECT} region=${REGION} state=${PROJECT}-development-tfstate:platform/database-engines/"

if [[ "${DRY_RUN}" != "true" ]]; then
  set_string "${DIR}/terraform.tfvars" project_name "${PROJECT}"
  set_string "${DIR}/terraform.tfvars" aws_region "${REGION}"
  set_string "${DIR}/backend.tf" bucket "${PROJECT}-development-tfstate"
  set_string "${DIR}/backend.tf" region "${REGION}"
fi

# ------------------------------------------------------------------------------
# GitHub Environments
# ------------------------------------------------------------------------------

gh_call() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "  [dry run] gh ${*}"
    if [[ "$*" == *"--input -"* ]]; then cat > /dev/null; fi
    return 0
  fi
  gh "$@"
}

reviewer_json() {
  local login id out="[]"
  IFS=',' read -ra logins <<< "${REVIEWERS}"
  for login in "${logins[@]}"; do
    if [[ "${DRY_RUN}" == "true" ]]; then
      id=0
    else
      id="$(gh api "users/${login}" --jq '.id')" || { echo "ERROR: could not find GitHub user '${login}'." >&2; exit 1; }
    fi
    out="$(jq -c --argjson id "${id}" '. + [{type: "User", id: $id}]' <<< "${out}")"
  done
  echo "${out}"
}

configure_environment() {
  local name="$1" restrict_to_main="$2" reviewers="$3" body

  body="$(jq -cn --argjson reviewers "${reviewers}" --argjson restrict "${restrict_to_main}" \
    '{reviewers: $reviewers}
     + (if $restrict then {deployment_branch_policy: {protected_branches: false, custom_branch_policies: true}}
        else {deployment_branch_policy: null} end)')"

  echo "  environment ${name}: reviewers=$(jq 'length' <<< "${reviewers}") main-only=${restrict_to_main}"

  printf '%s' "${body}" | gh_call api -X PUT "repos/${REPO}/environments/${name}" --input - >/dev/null

  if [[ "${restrict_to_main}" == "true" ]]; then
    # 422 means the policy already exists, which is the state we want.
    printf '%s' '{"name":"main","type":"branch"}' \
      | gh_call api -X POST "repos/${REPO}/environments/${name}/deployment-branch-policies" --input - >/dev/null 2>&1 || true
  fi

  gh_call variable set AWS_REGION --repo "${REPO}" --env "${name}" --body "${REGION}" >/dev/null
}

OWNER_ID="<owner id>"
REPOSITORY_ID="<repository id>"

if [[ "${SKIP_GITHUB}" == "true" ]]; then
  echo "GitHub Environments: skipped (--skip-github)."
else
  echo "GitHub Environments in ${REPO}"
  reviewers="[]"
  if [[ -n "${REVIEWERS}" ]]; then
    reviewers="$(reviewer_json)"
  else
    echo "  WARNING: no --reviewers given, so deploys need no approval."
  fi
  configure_environment development true "${reviewers}"
  configure_environment development-plan false "[]"

  if [[ "${DRY_RUN}" != "true" ]]; then
    OWNER_ID="$(gh api "repos/${REPO}" --jq '.owner.id')" || { echo "ERROR: could not read ${REPO}." >&2; exit 1; }
    REPOSITORY_ID="$(gh api "repos/${REPO}" --jq '.id')"
  fi
fi

if [[ "${DRY_RUN}" == "true" ]]; then
  echo
  echo "Dry run: nothing was written and GitHub was not called."
  exit 0
fi

echo
echo "Checking that no placeholder remains."
bash "${REPO_ROOT}/scripts/ci/check-placeholders.sh" "${DIR}"

cat <<NEXT

Done. Next:

  1. In core, set these in infrastructure/development/terraform.tfvars and let
     core apply them. They generate this repository's role:

       database_engines_repository          = "${REPO:-OWNER/REPOSITORY}"
       database_engines_repository_owner_id = "${OWNER_ID}"
       database_engines_repository_id       = "${REPOSITORY_ID}"

  2. Once core has applied it, connect this repository to its role:
       scripts/fetch-role-arn.sh --core OWNER/CORE-REPOSITORY

  3. Generate and commit infrastructure/development/.terraform.lock.hcl
     (docs/first-setup.md), commit these changes and open a pull request.

NEXT
