#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
F="${SCRIPTS}/fetch-role-arn.sh"
ARNS="${WORK}/role-arns.json"
export FAKE_GH_ROLE_ARNS_FILE="${ARNS}" FAKE_GH_LOG="${WORK}/gh.log"
run(){ : > "${FAKE_GH_LOG}"; bash "$F" --core acme/core --repo acme/database-engines; }

echo "== fetch-role-arn.sh"
echo '{"service_role_arns":{"acme/database-engines":"arn:aws:iam::123456789012:role/acme-development-database-engines"}}' > "${ARNS}"
run >/dev/null 2>&1; rc=$?
check "the ARN is found"                                    test $rc -eq 0
check "read from core's development role-arns"              grep -q 'repos/acme/core/contents/role-arns/development.json?ref=platform-outputs' "${FAKE_GH_LOG}"
check "set on the deploy environment"                       grep -q 'secret set TF_AWS_ROLE_ARN --repo acme/database-engines --env development --body arn:aws:iam::123456789012:role/' "${FAKE_GH_LOG}"
check "and on the plan environment"                         grep -q -- '--env development-plan --body arn:aws:iam::' "${FAKE_GH_LOG}"
echo '{"service_role_arns":{}}' > "${ARNS}"
out="$(run 2>&1)"
check "a missing role points at core's tfvars"              bash -c "grep -q 'database_engines_repository' <<< \"$out\""
echo '{"service_role_arns":{"acme/database-engines":"not-an-arn"}}' > "${ARNS}"
check "a malformed ARN is refused"                          bash -c "! run >/dev/null 2>&1"
: > "${ARNS}"
check "an unreadable core is reported"                      bash -c "! run >/dev/null 2>&1"
check "a bad --core is refused"                             bash -c "! bash '$F' --core nope >/dev/null 2>&1"
finish
