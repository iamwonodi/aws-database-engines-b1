#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
R="${SCRIPTS}/ci/read-contract.sh"
export FAKE_LOG="${WORK}/calls.log"
GOOD='{"schema_version":1,"hosting_model":"shared","ecr_registry_url":"123456789012.dkr.ecr.af-south-1.amazonaws.com","buckets":{"deploy":"acme-development-deploy"},"database":{"update_document":"acme-database-update"}}'

echo "== read-contract.sh"
out="$(FAKE_CONTRACT="$GOOD" bash "$R" acme af-south-1 2>&1)"; rc=$?
check "a development contract is read"                    test $rc -eq 0
check "it prints the deploy bucket"                       bash -c "grep -qx 'DEPLOY_BUCKET=acme-development-deploy' <<< \"$out\""
check "it prints the update document"                     bash -c "grep -qx 'UPDATE_DOCUMENT=acme-database-update' <<< \"$out\""
check "it prints the ECR registry"                        bash -c "grep -qx 'ECR_REGISTRY=123456789012.dkr.ecr.af-south-1.amazonaws.com' <<< \"$out\""
check "from /<project>/platform/config"                   grep -q -- '--name /acme/platform/config' "${FAKE_LOG}"
refuses(){ local contract="$1" want="$2" o; o="$(FAKE_CONTRACT="$contract" bash "$R" acme af-south-1 2>&1)" && return 1; grep -qF -- "$want" <<< "$o"; }
check "a missing parameter"                               bash -c "! bash '$R' acme af-south-1 >/dev/null 2>&1"
check "a newer contract"                                  refuses "$(jq -c '.schema_version=2' <<< "$GOOD")" "contract version 1"
check "a dedicated environment"                           refuses "$(jq -c '.hosting_model="dedicated"' <<< "$GOOD")" "only on the EC2 database host"
check "a core without update_document"                    refuses "$(jq -c 'del(.database.update_document)' <<< "$GOOD")" "database.update_document"
check "a null deploy bucket"                              refuses "$(jq -c '.buckets.deploy=null' <<< "$GOOD")" "buckets.deploy"
check "a document name with a space"                      refuses "$(jq -c '.database.update_document="AWS RunShellScript"' <<< "$GOOD")" "not a document name"
check "not JSON"                                          refuses "hello" "not a JSON object"
check "a bad project name"                                bash -c "! FAKE_CONTRACT='$GOOD' bash '$R' 'Bad' af-south-1 >/dev/null 2>&1"
finish
