#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
INIT="${SCRIPTS}/init-engines.sh"
SOURCE_ROOT="$(cd "${SCRIPTS}/.." && pwd)"
export FAKE_GH_REPO_JSON='{"id":987,"owner":{"id":123}}'

fresh(){
  rm -rf "${WORK}/repo"; mkdir -p "${WORK}/repo/scripts/ci" "${WORK}/repo/infrastructure"
  cp -r "${SOURCE_ROOT}/infrastructure/development" "${WORK}/repo/infrastructure/"
  rm -rf "${WORK}/repo/infrastructure/development/.terraform"
  cp "${SCRIPTS}/ci/check-placeholders.sh" "${WORK}/repo/scripts/ci/"
  git -C "${WORK}/repo" init -q; git -C "${WORK}/repo" remote add origin https://github.com/acme/database-engines.git
  export INIT_REPO_ROOT="${WORK}/repo" FAKE_GH_LOG="${WORK}/gh.log"; : > "${FAKE_GH_LOG}"
}
D="${WORK}/repo/infrastructure/development"
run(){ bash "${INIT}" --project acme --region af-south-1 "$@"; }

echo "== init-engines.sh"
fresh; run --reviewers alice > "${WORK}/out.txt" 2>&1; rc=$?
check "run succeeds"                                       test $rc -eq 0
check "project_name is set"                                grep -qx 'project_name = "acme"' "$D/terraform.tfvars"
check "aws_region is set"                                  grep -qx 'aws_region   = "af-south-1"' "$D/terraform.tfvars"
check "the state bucket is set"                            grep -q 'bucket = "acme-development-tfstate"' "$D/backend.tf"
check "the backend region is set"                          grep -qE 'region += "af-south-1"' "$D/backend.tf"
check "the state key keeps core's prefix"                  grep -q 'key = "platform/database-engines/terraform.tfstate"' "$D/backend.tf"
check "no placeholder remains"                             bash "${WORK}/repo/scripts/ci/check-placeholders.sh" "$D"
check "the development environment is main-only"          bash -c "grep -A1 'environments/development --input' '${FAKE_GH_LOG}' | grep -q 'custom_branch_policies\":true'"
check "the deploy requires the reviewer"                   bash -c "grep -A1 'environments/development --input' '${FAKE_GH_LOG}' | grep -q '\"id\":4242'"
check "the plan environment exists"                        grep -q 'environments/development-plan --input' "${FAKE_GH_LOG}"
check "AWS_REGION is set on both environments"            bash -c "[ \$(grep -c 'variable set AWS_REGION --repo acme/database-engines' '${FAKE_GH_LOG}') -eq 2 ]"
check "core's tfvars lines are printed with the IDs"       bash -c "grep -q 'database_engines_repository          = \"acme/database-engines\"' '${WORK}/out.txt' && grep -q 'owner_id = \"123\"' '${WORK}/out.txt' && grep -q 'repository_id       = \"987\"' '${WORK}/out.txt'"
fresh; run >/dev/null 2>&1; run > "${WORK}/out2.txt" 2>&1
check "re-running is safe"                                 bash -c "[ \$? -eq 0 ] && grep -qx 'project_name = \"acme\"' '$D/terraform.tfvars'"
check "no reviewers is warned about"                       grep -q 'WARNING: no --reviewers' "${WORK}/out2.txt"
fresh; run --dry-run >/dev/null 2>&1
check "a dry run writes nothing"                           grep -q 'CHANGE_ME' "$D/terraform.tfvars"
check "and calls no GitHub"                                bash -c "[ ! -s '${FAKE_GH_LOG}' ]"
fresh; run --skip-github >/dev/null 2>&1
check "--skip-github writes the files only"                bash -c "grep -qx 'project_name = \"acme\"' '$D/terraform.tfvars' && [ ! -s '${FAKE_GH_LOG}' ]"
fresh
check "a bad project is refused"                           bash -c "! bash '${INIT}' --project Acme --region af-south-1 >/dev/null 2>&1"
check "a bad region is refused"                            bash -c "! bash '${INIT}' --project acme --region africa >/dev/null 2>&1"
check "bad reviewers are refused"                          bash -c "! bash '${INIT}' --project acme --region af-south-1 --reviewers 'a b' >/dev/null 2>&1"
check "an unknown user fails"                              bash -c "! FAKE_GH_NO_USER=1 bash '${INIT}' --project acme --region af-south-1 --reviewers ghost >/dev/null 2>&1"
finish
