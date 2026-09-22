#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
P="${SCRIPTS}/ci/publish-engines.sh"
REPO_DB="$(cd "${SCRIPTS}/../database" && pwd)"
IMG="123456789012.dkr.ecr.af-south-1.amazonaws.com/engines/postgres:17-amd64-0123456789ab"
export FAKE_LOG="${WORK}/calls.log" FAKE_S3_DIR="${WORK}/s3"

fresh(){ rm -rf "${WORK}/db" "${WORK}/s3"; cp -R "${REPO_DB}" "${WORK}/db"; mkdir -p "${WORK}/s3"; : > "${FAKE_LOG}"; : > "${WORK}/images.env"; }
activate(){ jq "$1" "${WORK}/db/registry.json" > "${WORK}/r" && mv "${WORK}/r" "${WORK}/db/registry.json"; }
run(){ bash "$P" "${WORK}/db" "${WORK}/images.env" acme-development-deploy af-south-1; }
S3="${WORK}/s3/database"

echo "== publish-engines.sh"
fresh; activate '.postgres.active=true'; echo "postgres=${IMG}" > "${WORK}/images.env"
run >/dev/null 2>&1; rc=$?
check "an active engine is published"                     test $rc -eq 0
check "its compose file as committed"                     cmp -s "${WORK}/db/engines/postgres/docker-compose.yaml" "${S3}/engines/postgres/docker-compose.yaml"
check "its .env keeps the secret pointer"                 grep -q '^POSTGRES_PASSWORD=__FROM_SECRET__:CORE_ROOT_SECRET_ARN:root_password$' "${S3}/engines/postgres/.env"
check "and gains its ECR image"                           grep -qx "ENGINE_IMAGE=${IMG}" "${S3}/engines/postgres/.env"
check "image.json stays behind"                           test ! -e "${S3}/engines/postgres/image.json"
check "inactive engines are not published"                bash -c "[ ! -e '${S3}/engines/mysql' ] && [ ! -e '${S3}/engines/mongodb' ]"
check "the registry is published whole"                   cmp -s "${WORK}/db/registry.json" "${S3}/registry.json"
check "engines first, registry last"                      bash -c "tail -n1 '${FAKE_LOG}' | grep -q 's3 cp .*registry.json' && head -n1 '${FAKE_LOG}' | grep -q 's3 sync'"
check "the engines prefix is synced with --delete"        grep -q 's3 sync .* s3://acme-development-deploy/database/engines/ --delete' "${FAKE_LOG}"

fresh; activate '.postgres.active=true'; printf 'POSTGRES_PASSWORD=__FROM_SECRET__:CORE_ROOT_SECRET_ARN:root_password' > "${WORK}/db/engines/postgres/.env"
echo "postgres=${IMG}" > "${WORK}/images.env"; run >/dev/null 2>&1
check "ENGINE_IMAGE is never glued onto a last line"      bash -c "[ \$(grep -c '' '${S3}/engines/postgres/.env') -eq 2 ] && grep -qx 'ENGINE_IMAGE=${IMG}' '${S3}/engines/postgres/.env'"

fresh; run >/dev/null 2>&1
check "nothing active still publishes the registry"       cmp -s "${WORK}/db/registry.json" "${S3}/registry.json"
fresh; activate '.mysql.active=true'
check "an active engine with no mirrored image fails"     bash -c "! run >/dev/null 2>&1"
check "and publishes nothing"                             bash -c "! grep -q 's3 ' '${FAKE_LOG}'"
fresh; activate '.postgres.active=true'; echo "postgres=${IMG}" > "${WORK}/images.env"
check "an upload failure fails before the registry"       bash -c "! FAKE_S3_FAIL=1 run >/dev/null 2>&1 && [ ! -e '${S3}/registry.json' ]"
check "a missing images file is refused"                  bash -c "! bash '$P' '${WORK}/db' '${WORK}/none' b-u-c af-south-1 >/dev/null 2>&1"
check "a bad bucket name is refused"                      bash -c "! bash '$P' '${WORK}/db' '${WORK}/images.env' 'Bad_Bucket' af-south-1 >/dev/null 2>&1"
finish
