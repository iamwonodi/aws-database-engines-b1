#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
U="${SCRIPTS}/ci/send-update.sh"
export FAKE_LOG="${WORK}/calls.log" UPDATE_INTERVAL=0 UPDATE_TIMEOUT=30 UPDATE_EMPTY_GRACE=30

seq_dir(){ rm -rf "${WORK}/inv"; mkdir -p "${WORK}/inv"; export FAKE_INVOCATIONS_DIR="${WORK}/inv"; : > "${FAKE_LOG}"; }
inv(){ printf '%s' "$2" > "${WORK}/inv/$1.json"; }
run(){ bash "$U" acme-database-update acme af-south-1; }
OK='[{"id":"i-db","status":"Success","out":"Engine: postgres (port 5432, active: true)"}]'

echo "== send-update.sh"
seq_dir; inv 1 "$OK"
out="$(run 2>&1)"; rc=$?
check "succeeds when the host reports Success"            test $rc -eq 0
check "sends core's update document"                      grep -q -- '--document-name acme-database-update' "${FAKE_LOG}"
check "to the database host only"                         grep -q -- '--targets Key=tag:Project,Values=acme Key=tag:Service,Values=database-hub' "${FAKE_LOG}"
check "with no parameters"                                bash -c "! grep -q -- '--parameters' '${FAKE_LOG}'"
check "never AWS-RunShellScript"                          bash -c "! grep -q RunShellScript '${FAKE_LOG}'"
check "the host's output is shown"                        bash -c "grep -q 'active: true' <<< \"$out\""
seq_dir; inv 1 '[{"id":"i-db","status":"InProgress","out":""}]'; inv 2 "$OK"
run >/dev/null 2>&1
check "waits while it is still running"                   test $? -eq 0
seq_dir; inv 1 '[{"id":"i-db","status":"Failed","out":"ERROR: postgres failed to deploy (exit 1)."}]'
out="$(run 2>&1)"; rc=$?
check "a failed update fails the workflow"                test $rc -ne 0
check "and the reason is shown"                           bash -c "grep -q 'failed to deploy' <<< \"$out\""
seq_dir; inv 1 '[]'
check "no database host answering fails"                  bash -c "! UPDATE_EMPTY_GRACE=1 UPDATE_INTERVAL=1 run >/dev/null 2>&1"
seq_dir; inv 1 '[{"id":"i-db","status":"InProgress","out":""}]'
check "a host that never finishes fails after the timeout" bash -c "! UPDATE_TIMEOUT=1 UPDATE_INTERVAL=1 run >/dev/null 2>&1"
seq_dir; inv 1 "$OK"
check "a send failure is reported"                        bash -c "! FAKE_SEND_FAIL=1 run >/dev/null 2>&1"
check "a document name with a space is refused"           bash -c "! bash '$U' 'AWS RunShellScript' acme af-south-1 >/dev/null 2>&1"
check "a bad project name is refused"                     bash -c "! bash '$U' acme-database-update 'Bad Name' af-south-1 >/dev/null 2>&1"
finish
