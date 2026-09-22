#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
V="${SCRIPTS}/ci/validate-engines.sh"
REPO_DB="$(cd "${SCRIPTS}/../database" && pwd)"
export FAKE_LOG="${WORK}/calls.log"

fresh(){ rm -rf "${WORK}/db"; cp -R "${REPO_DB}" "${WORK}/db"; : > "${FAKE_LOG}"; }
reg(){ printf '%s' "$1" > "${WORK}/db/registry.json"; }
rejects(){ local want="$1" out rc; out="$(bash "$V" "${WORK}/db" 2>&1)"; rc=$?; [[ $rc -ne 0 ]] && grep -qF -- "$want" <<< "$out"; }

echo "== validate-engines.sh"
fresh
check "the blueprint's own definitions are valid"        bash "$V" "${WORK}/db"
check "the compose files are rendered when docker exists" grep -q 'compose --project-directory' "${FAKE_LOG}"
check "the source tree is not written to"                bash -c "[ ! -e '${WORK}/db/engines/postgres/.resolved' ]"
check "rendering can be switched off"                    bash -c ": > '${FAKE_LOG}'; VALIDATE_RENDER=false bash '$V' '${WORK}/db' >/dev/null && ! grep -q compose '${FAKE_LOG}'"
fresh; export FAKE_RENDER_FAIL=1
check "a compose file docker cannot render is refused"   rejects "could not render"
unset FAKE_RENDER_FAIL

fresh; reg '[1,2]';                                        check "a registry that is not an object"          rejects "JSON object"
fresh; reg '{"Postgres":{"port":5432}}';                  check "an invalid engine name"                    rejects "not a valid engine name"
fresh; reg '{"postgres":{"port":"5432"}}';                check "a string port"                             rejects "integer port"
fresh; reg '{"postgres":{"port":80}}';                     check "a privileged port"                         rejects "port 80 must be from 1024 to 65535"
fresh; reg '{"postgres":{"port":5432,"active":"yes"}}';   check "a non-boolean active"                      rejects "active must be true or false"
fresh; reg '{"postgres":{"port":5432,"acitve":false}}';   check "a misspelt field"                          rejects "unknown fields: acitve"
fresh; reg '{"postgres":{"port":5432,"active":false},"mysql":{"port":5432,"active":false}}'
check "a shared port, even between inactive engines"     rejects "port 5432 is used by more than one engine"
fresh; reg '{"redis":{"port":6379}}';                     check "a registered engine with no folder"        rejects "redis: registered"
fresh; reg '{"postgres":{"port":5432}}'
out="$(bash "$V" "${WORK}/db" 2>&1)"
check "unregistered folders only warn"                    bash -c "grep -q 'WARNING: .*mysql/ is not in registry.json' <<< \"$out\""
check "an absent active counts as active"                 bash -c "grep -q 'Active: postgres' <<< \"$out\""
fresh; reg '{"postgres":{"port":5433},"mysql":{"port":3306},"mongodb":{"port":27017}}'
check "a host port that is not the engine's port"        rejects 'registry says port 5433 but the compose file publishes ${ENGINE_PORT}:5432'
fresh; sed -i 's|"${ENGINE_PORT}:3306"|"${ENGINE_PORT}:3306"\n      - "${ENGINE_PORT}:33060"|' "${WORK}/db/engines/mysql/docker-compose.yaml"
check "the engine port published twice"                  rejects 'publish ${ENGINE_PORT} exactly once'

fresh; sed -i 's|image: ${ENGINE_IMAGE}|image: postgres:17|' "${WORK}/db/engines/postgres/docker-compose.yaml"
check "an image not from the publish step"               rejects "image: \${ENGINE_IMAGE}"
fresh; sed -i 's|env_file: .resolved/.env|env_file: .env|' "${WORK}/db/engines/mysql/docker-compose.yaml"
check "the unresolved .env as env_file"                  rejects "env_file: .resolved/.env"
fresh; sed -i 's|${DATA_ROOT}/${ENGINE_NAME}|/var/lib/pg|' "${WORK}/db/engines/postgres/docker-compose.yaml"
check "data kept off the persistent volume"              rejects "under \${DATA_ROOT}/\${ENGINE_NAME}"
fresh; sed -i 's|"${ENGINE_PORT}:27017"|"27017:27017"|' "${WORK}/db/engines/mongodb/docker-compose.yaml"
check "a fixed host port instead of the registry's"      rejects 'publish "${ENGINE_PORT}:<port>"'
fresh; rm "${WORK}/db/engines/mysql/docker-compose.yaml"
check "a folder with no compose file"                    rejects "mysql: no docker-compose.yaml"

fresh; echo 'POSTGRES_PASSWORD=hunter2' > "${WORK}/db/engines/postgres/.env"
check "a literal password"                               rejects "sets POSTGRES_PASSWORD to a literal"
fresh; echo 'API_TOKEN=abc' > "${WORK}/db/engines/postgres/.env"
check "a literal token"                                  rejects "sets API_TOKEN to a literal"
fresh; echo 'ENGINE_PORT=5432' >> "${WORK}/db/engines/postgres/.env"
check "a reserved name"                                  rejects "defines ENGINE_PORT, which the platform provides"
fresh; echo 'ENGINE_IMAGE=postgres:17' >> "${WORK}/db/engines/postgres/.env"
check "ENGINE_IMAGE is reserved too"                     rejects "defines ENGINE_IMAGE"
fresh; printf 'POSTGRES_PASSWORD=__FROM_SECRET__:CORE_ROOT_SECRET_ARN:root_password\r\n' > "${WORK}/db/engines/postgres/.env"
check "Windows line endings"                             rejects "Windows line endings"
fresh; echo 'not a pair' >> "${WORK}/db/engines/postgres/.env"
check "a line that is not KEY=VALUE"                     rejects "is not KEY=VALUE"
fresh; rm "${WORK}/db/engines/postgres/.env"
check "a folder with no .env"                            rejects "postgres: no .env"

fresh; echo '{"source":"postgres@sha256:abc","platform":"linux/amd64"}' > "${WORK}/db/engines/postgres/image.json"
check "a digest in image.json"                           rejects "source must be <image>:<tag>"
fresh; echo '{"source":"postgres","platform":"linux/amd64"}' > "${WORK}/db/engines/postgres/image.json"
check "an image with no tag"                             rejects "source must be <image>:<tag>"
fresh; echo '{"source":"postgres:17","platform":"windows/amd64"}' > "${WORK}/db/engines/postgres/image.json"
check "an unsupported platform"                          rejects "platform must be linux/amd64 or linux/arm64"
fresh; echo '{"source":"public.ecr.aws/docker/library/postgres:17","platform":"linux/arm64"}' > "${WORK}/db/engines/postgres/image.json"
check "a registry-qualified source on arm64 is fine"     bash "$V" "${WORK}/db"
check "a missing directory argument is refused"          bash -c "! bash '$V' '${WORK}/nope' >/dev/null 2>&1"
finish
