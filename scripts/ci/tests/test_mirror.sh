#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
M="${SCRIPTS}/ci/mirror-images.sh"
REPO_DB="$(cd "${SCRIPTS}/../database" && pwd)"
REG="123456789012.dkr.ecr.af-south-1.amazonaws.com"
TAG="17-amd64-0123456789ab"
export FAKE_LOG="${WORK}/calls.log"

fresh(){ rm -rf "${WORK}/db"; cp -R "${REPO_DB}" "${WORK}/db"; : > "${FAKE_LOG}"; unset FAKE_ECR_REPO_EXISTS FAKE_ECR_TAGS FAKE_INSPECT_FAIL; }
activate(){ jq "$1" "${WORK}/db/registry.json" > "${WORK}/r" && mv "${WORK}/r" "${WORK}/db/registry.json"; }
run(){ bash "$M" "${WORK}/db" "$REG" af-south-1 "${WORK}/images.env"; }

echo "== mirror-images.sh"
fresh; out="$(run 2>&1)"; rc=$?
check "nothing active: nothing mirrored"                  bash -c "[ $rc -eq 0 ] && grep -q 'No active engines' <<< \"$out\" && [ ! -s '${WORK}/images.env' ]"
check "and no ECR login"                                  bash -c "! grep -q 'ecr get-login-password' '${FAKE_LOG}'"

fresh; activate '.postgres.active=true'
run >/dev/null 2>&1; rc=$?
check "an active engine is mirrored"                      test $rc -eq 0
check "the tag pins platform and digest"                  grep -qx "postgres=${REG}/engines/postgres:${TAG}" "${WORK}/images.env"
check "only active engines are mirrored"                  bash -c "[ \$(wc -l < '${WORK}/images.env') -eq 1 ]"
check "the repository is created tag-immutable"           grep -q 'ecr create-repository --repository-name engines/postgres --image-tag-mutability IMMUTABLE --image-scanning-configuration scanOnPush=true' "${FAKE_LOG}"
check "it pulls by digest, for the host's platform"       grep -q 'docker pull --quiet --platform linux/amd64 postgres@sha256:0123456789abcdef' "${FAKE_LOG}"
check "and pushes to this account's ECR"                  grep -q "docker push --quiet ${REG}/engines/postgres:${TAG}" "${FAKE_LOG}"

fresh; activate '.postgres.active=true'; export FAKE_ECR_REPO_EXISTS=true FAKE_ECR_TAGS="${TAG}"
run >/dev/null 2>&1
check "an existing tag is not copied again"               bash -c "! grep -qE 'docker (pull|push)' '${FAKE_LOG}' && ! grep -q create-repository '${FAKE_LOG}'"
check "but is still reported for publishing"              grep -qx "postgres=${REG}/engines/postgres:${TAG}" "${WORK}/images.env"

fresh; activate '.postgres.active=true | .mysql.active=true'; export FAKE_INSPECT_FAIL=1
check "an upstream tag that does not resolve fails"      bash -c "! run >/dev/null 2>&1"
unset FAKE_INSPECT_FAIL
fresh; activate '.mysql.active=true'
IMAGE_REPOSITORY_PREFIX=mirror run >/dev/null 2>&1
check "the repository prefix can follow core's"           grep -qx "mysql=${REG}/mirror/mysql:8.4-amd64-0123456789ab" "${WORK}/images.env"
fresh; activate '.mysql.active=true'
check "a digest that is not sha256 is refused"            bash -c "! FAKE_DIGEST=md5:abc run >/dev/null 2>&1"
check "a registry that is not ECR is refused"             bash -c "! bash '$M' '${WORK}/db' docker.io af-south-1 '${WORK}/i' >/dev/null 2>&1"
finish
