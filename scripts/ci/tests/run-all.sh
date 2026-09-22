#!/usr/bin/env bash
# Offline tests for the scripts in this repository (needs bash, git, jq; aws, docker and gh are faked).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
failed=0
for suite in test_validate.sh test_read_contract.sh test_mirror.sh test_publish.sh test_send_update.sh test_init.sh test_roles.sh test_placeholders.sh test_lock_files.sh; do
  echo "################ ${suite}"
  bash "./${suite}" || failed=1
done
[[ ${failed} -eq 0 ]] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
