#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# CONNECT THIS REPOSITORY TO ITS ROLE
#
# Core generates this repository's role from database_engines_repository in its
# development tfvars, and after applying publishes every role ARN to
# role-arns/development.json on its platform-outputs branch. This reads this
# repository's ARN from there and sets it as the TF_AWS_ROLE_ARN secret on both
# GitHub Environments: development (deploy) and development-plan (plan).
# Environment secrets are not shared between them.
#
# It needs no admin access to core: the file is a generated, non-secret list.
#
# Usage: scripts/fetch-role-arn.sh --core OWNER/CORE-REPO [--repo OWNER/REPO]
# Needs: gh (authenticated), jq, base64.
# ==============================================================================

REPO_ROOT="${INIT_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CORE="" REPO=""
ENVIRONMENT="development"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --core) CORE="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    *) echo "ERROR: unknown argument '$1'." >&2; exit 1 ;;
  esac
done

[[ "${CORE}" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] || { echo "ERROR: --core must be OWNER/REPOSITORY." >&2; exit 1; }

for command in gh jq base64; do
  command -v "${command}" >/dev/null 2>&1 || { echo "ERROR: required command not found: ${command}" >&2; exit 1; }
done

if [[ -z "${REPO}" ]]; then
  REMOTE_URL="$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null || true)"
  [[ -n "${REMOTE_URL}" ]] || { echo "ERROR: no origin remote; pass --repo OWNER/REPO." >&2; exit 1; }
  REPO="$(sed -E 's#^(https?://[^/]+/|git@[^:]+:|ssh://[^/]+/)##; s#\.git$##; s#/$##' <<< "${REMOTE_URL}")"
fi

RESPONSE="$(gh api "repos/${CORE}/contents/role-arns/${ENVIRONMENT}.json?ref=platform-outputs" 2>/dev/null)" \
  || { echo "ERROR: could not read role-arns/${ENVIRONMENT}.json on ${CORE}'s platform-outputs branch." >&2
       echo "       Has core applied its development environment, and can you read ${CORE}?" >&2; exit 1; }

DOCUMENT="$(jq -r '.content' <<< "${RESPONSE}" | base64 -d)" \
  || { echo "ERROR: the role-arns file could not be decoded." >&2; exit 1; }

ARN="$(jq -r --arg r "${REPO}" '.service_role_arns[$r] // empty' <<< "${DOCUMENT}")"

if [[ -z "${ARN}" ]]; then
  echo "ERROR: ${REPO} has no role in ${CORE}'s ${ENVIRONMENT} role-arns." >&2
  echo "       Set database_engines_repository (and its IDs) in core's development tfvars and let core apply it." >&2
  exit 1
fi

if ! [[ "${ARN}" =~ ^arn:aws:iam::[0-9]{12}:role/.+ ]]; then
  echo "ERROR: '${ARN}' does not look like an IAM role ARN." >&2
  exit 1
fi

for TARGET in "${ENVIRONMENT}" "${ENVIRONMENT}-plan"; do
  echo "Setting TF_AWS_ROLE_ARN on ${REPO}'s ${TARGET} environment."
  gh secret set TF_AWS_ROLE_ARN --repo "${REPO}" --env "${TARGET}" --body "${ARN}" \
    || { echo "ERROR: could not set the secret on ${TARGET}. Create the environments first: scripts/init-engines.sh" >&2; exit 1; }
done

echo "Done: ${REPO} will assume ${ARN} in ${ENVIRONMENT}."
