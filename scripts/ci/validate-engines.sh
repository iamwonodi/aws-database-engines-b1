#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# VALIDATE THE ENGINE REGISTRY AND EVERY ENGINE FOLDER BEFORE ANYTHING IS PUBLISHED
#
# The database host (core's update.sh) re-checks the registry and refuses a bad
# one, but by then the engine folders are already in the bucket. This catches
# the same mistakes on the pull request, plus what only this repository knows:
# the allocated port range and the shape of each engine folder.
#
# registry.json   a JSON object keyed by engine name
#                 name     ^[a-z0-9][a-z0-9-]{0,40}$ (the host's rule)
#                 port     integer in the allocated range, unique across ALL
#                          engines, active or not, so an allocation never moves
#                 active   boolean, optional (the host treats absent as true)
#
# engines/<engine>/  for every registered engine
#   docker-compose.yaml (or .yml)
#       image: ${ENGINE_IMAGE}          the publish step supplies the ECR image
#       env_file: .resolved/.env        the secret-resolved copy
#       publishes ${ENGINE_PORT}
#       keeps its data under ${DATA_ROOT}/${ENGINE_NAME}
#   .env
#       KEY=VALUE lines or comments, no CR
#       no reserved name: DATA_ROOT ENGINE_NAME ENGINE_PORT CORE_ROOT_SECRET_ARN
#       ENGINE_IMAGE
#       every *PASSWORD*, *SECRET*, *TOKEN* or *KEY* value is a __FROM_SECRET__
#       pointer, never a literal
#   image.json      {"source": "<image>:<tag>", "platform": "linux/amd64|linux/arm64"}
#
# With docker available (CI), each compose file is also rendered with
# "docker compose config" to catch YAML mistakes.
#
# Usage: validate-engines.sh <database-dir>
#
# Environment (optional):
#   ENGINE_PORT_MIN   lowest allocatable port   (default 20001)
#   ENGINE_PORT_MAX   highest allocatable port  (default 20099)
#   VALIDATE_RENDER   "false" skips the docker compose render
# ==============================================================================

DATABASE_DIR="${1:?Usage: validate-engines.sh <database-dir>}"
DATABASE_DIR="${DATABASE_DIR%/}"

PORT_MIN="${ENGINE_PORT_MIN:-20001}"
PORT_MAX="${ENGINE_PORT_MAX:-20099}"
RENDER="${VALIDATE_RENDER:-true}"

REGISTRY="${DATABASE_DIR}/registry.json"
ENGINES_DIR="${DATABASE_DIR}/engines"

command -v jq >/dev/null 2>&1 || { echo "ERROR: required command not found: jq" >&2; exit 1; }

errors=()
err() { errors+=("$1"); }

# ------------------------------------------------------------------------------
# The registry
# ------------------------------------------------------------------------------

[[ -f "${REGISTRY}" ]] || { echo "ERROR: ${REGISTRY} not found." >&2; exit 1; }

if ! jq -e 'type == "object"' "${REGISTRY}" >/dev/null 2>&1; then
  echo "ERROR: ${REGISTRY} must be a JSON object keyed by engine name." >&2
  exit 1
fi

while IFS= read -r message; do
  [[ -n "${message}" ]] && err "${message}"
done < <(jq -r --argjson min "${PORT_MIN}" --argjson max "${PORT_MAX}" '
  (to_entries[]
    | .key as $name | .value as $v
    | if ($name | test("^[a-z0-9][a-z0-9-]{0,40}$") | not)
        then "registry: \"\($name)\" is not a valid engine name (lowercase letters, digits, hyphens)"
      elif ($v | type) != "object"
        then "registry: \"\($name)\" must be an object"
      elif (($v.port | type) != "number") or ($v.port != ($v.port | floor))
        then "registry: \"\($name)\" needs an integer port"
      elif ($v.port < $min) or ($v.port > $max)
        then "registry: \"\($name)\" port \($v.port) is outside the allocated range \($min)-\($max)"
      elif ($v | has("active")) and (($v.active | type) != "boolean")
        then "registry: \"\($name)\" active must be true or false"
      elif (($v | keys) - ["port", "active"] | length) > 0
        then "registry: \"\($name)\" has unknown fields: \(($v | keys) - ["port", "active"] | join(", "))"
      else empty end),
  ([to_entries[] | select((.value | type) == "object" and (.value.port | type) == "number") | {key, port: .value.port}]
    | group_by(.port) | map(select(length > 1))[]
    | "registry: port \(.[0].port) is allocated to more than one engine: \(map(.key) | join(", "))")
' "${REGISTRY}")

mapfile -t ENGINES < <(jq -r 'keys[]' "${REGISTRY}")

# ------------------------------------------------------------------------------
# Each registered engine's folder
# ------------------------------------------------------------------------------

RESERVED='^(DATA_ROOT|ENGINE_NAME|ENGINE_PORT|CORE_ROOT_SECRET_ARN|ENGINE_IMAGE)='
SENSITIVE='(PASSWORD|SECRET|TOKEN|KEY)'
SENTINEL='__FROM_SECRET__:[A-Za-z_][A-Za-z0-9_]*(:[A-Za-z0-9_.-]+)?'

check_compose() {
  local engine="$1" file="$2"

  grep -qE '^[[:space:]]*image:[[:space:]]*"?\$\{ENGINE_IMAGE\}"?[[:space:]]*$' "${file}" \
    || err "${engine}: the compose file must use image: \${ENGINE_IMAGE} (the publish step supplies the ECR image)"

  [[ "$(grep -cE '^[[:space:]]*image:' "${file}")" -eq 1 ]] \
    || err "${engine}: the compose file must define exactly one service image"

  grep -qE '^[[:space:]]*env_file:[[:space:]]*"?\.resolved/\.env"?[[:space:]]*$' "${file}" \
    || err "${engine}: the compose file must load env_file: .resolved/.env"

  grep -qF '${ENGINE_PORT}:' "${file}" \
    || err "${engine}: the compose file must publish \${ENGINE_PORT}"

  grep -qF '${DATA_ROOT}/${ENGINE_NAME}' "${file}" \
    || err "${engine}: the compose file must keep its data under \${DATA_ROOT}/\${ENGINE_NAME}"
}

check_env() {
  local engine="$1" file="$2" number=0 line key value

  if grep -q $'\r' "${file}"; then
    err "${engine}: .env has Windows line endings (CR); save it with LF"
  fi

  while IFS= read -r line || [[ -n "${line}" ]]; do
    number=$((number + 1))
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue

    if ! [[ "${line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      err "${engine}: .env line ${number} is not KEY=VALUE"
      continue
    fi

    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"

    if [[ "${line}" =~ ${RESERVED} ]]; then
      err "${engine}: .env line ${number} defines ${key}, which the platform provides"
    fi

    if [[ "${key}" =~ ${SENSITIVE} && ! "${value}" =~ ^${SENTINEL}$ ]]; then
      err "${engine}: .env line ${number} sets ${key} to a literal; reference a secret with __FROM_SECRET__:<ARN_VAR>:<field>"
    fi
  done < "${file}"
}

check_image() {
  local engine="$1" file="$2"

  if ! jq -e 'type == "object"' "${file}" >/dev/null 2>&1; then
    err "${engine}: image.json must be a JSON object"
    return
  fi

  jq -e '(.source | type) == "string" and (.source | test("^[a-z0-9]+([._/-][a-z0-9]+)*:[A-Za-z0-9_][A-Za-z0-9_.-]{0,100}$"))' "${file}" >/dev/null \
    || err "${engine}: image.json source must be <image>:<tag>, with no digest (the mirror step pins the digest)"

  jq -e '.platform == "linux/amd64" or .platform == "linux/arm64"' "${file}" >/dev/null \
    || err "${engine}: image.json platform must be linux/amd64 or linux/arm64 (the database host's architecture)"

  jq -e '(keys - ["source", "platform"]) | length == 0' "${file}" >/dev/null \
    || err "${engine}: image.json has unknown fields"
}

# Rendered in a scratch copy, so the source tree is never written to.
render_compose() {
  local engine="$1" dir="$2" file="$3" scratch
  scratch="$(mktemp -d)"
  cp -R "${dir}/." "${scratch}/"
  mkdir -p "${scratch}/.resolved"
  cp "${scratch}/.env" "${scratch}/.resolved/.env" 2>/dev/null || : > "${scratch}/.resolved/.env"
  printf 'ENGINE_IMAGE=example.invalid/engines/%s:0\nENGINE_PORT=20001\nENGINE_NAME=%s\nDATA_ROOT=/srv/data\n' "${engine}" "${engine}" > "${scratch}/.platform.env"

  if ! docker compose --project-directory "${scratch}" --file "${scratch}/$(basename "${file}")" \
      --env-file "${scratch}/.platform.env" config --quiet >/dev/null 2>&1; then
    err "${engine}: docker compose could not render $(basename "${file}")"
  fi

  rm -rf "${scratch}"
}

for engine in "${ENGINES[@]}"; do
  dir="${ENGINES_DIR}/${engine}"

  if [[ ! -d "${dir}" ]]; then
    err "${engine}: registered, but ${dir} does not exist"
    continue
  fi

  compose=""
  for name in docker-compose.yaml docker-compose.yml; do
    [[ -f "${dir}/${name}" ]] && { compose="${dir}/${name}"; break; }
  done

  if [[ -z "${compose}" ]]; then
    err "${engine}: no docker-compose.yaml"
  else
    check_compose "${engine}" "${compose}"
  fi

  if [[ -f "${dir}/.env" ]]; then check_env "${engine}" "${dir}/.env"; else err "${engine}: no .env"; fi
  if [[ -f "${dir}/image.json" ]]; then check_image "${engine}" "${dir}/image.json"; else err "${engine}: no image.json"; fi

  if [[ -n "${compose}" && "${RENDER}" == "true" ]] && command -v docker >/dev/null 2>&1; then
    render_compose "${engine}" "${dir}" "${compose}"
  fi
done

# A folder nobody registered is never started. Worth a warning, not a failure.
shopt -s nullglob
for dir in "${ENGINES_DIR}"/*/; do
  name="$(basename "${dir}")"
  jq -e --arg n "${name}" 'has($n)' "${REGISTRY}" >/dev/null \
    || echo "WARNING: ${dir} is not in registry.json and will not be published."
done
shopt -u nullglob

if [[ ${#errors[@]} -gt 0 ]]; then
  echo "ERROR: the engine definitions were rejected:" >&2
  printf '       - %s\n' "${errors[@]}" >&2
  exit 1
fi

active="$(jq -r '[to_entries[] | select(.value.active != false) | .key] | if length == 0 then "none" else join(", ") end' "${REGISTRY}")"
echo "Engine definitions are valid. Registered: ${#ENGINES[@]}. Active: ${active}."
