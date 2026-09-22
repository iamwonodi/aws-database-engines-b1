#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# PUBLISH THE ENGINES TO THE DEPLOY BUCKET: ENGINE FOLDERS FIRST, REGISTRY LAST
#
# The database host starts only engines listed in registry.json, so uploading
# the folders first means a half-finished run can never start anything. The
# registry goes up last, as one object.
#
# Each ACTIVE engine is staged as:
#   database/engines/<engine>/docker-compose.yaml   as committed
#   database/engines/<engine>/.env                  as committed, plus
#                                                   ENGINE_IMAGE=<its mirrored ECR image>
#
# image.json stays behind: it is this repository's input, not the host's.
#
# The engines prefix is synced with --delete, so an inactive engine's folder
# leaves the bucket. That never stops anything: the host stops an engine only
# on "active": false in the registry, and leaves an engine with no folder alone.
#
# Usage: publish-engines.sh <database-dir> <images-file> <bucket> <aws-region>
#   images-file   written by mirror-images.sh: <engine>=<image> per line
# ==============================================================================

DATABASE_DIR="${1:?Usage: publish-engines.sh <database-dir> <images-file> <bucket> <aws-region>}"
IMAGES_FILE="${2:?images-file is required}"
BUCKET="${3:?bucket is required}"
REGION="${4:?aws-region is required}"

DATABASE_DIR="${DATABASE_DIR%/}"

[[ "${BUCKET}" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || { echo "ERROR: '${BUCKET}' is not a bucket name." >&2; exit 1; }
[[ -f "${IMAGES_FILE}" ]] || { echo "ERROR: ${IMAGES_FILE} not found; run mirror-images.sh first." >&2; exit 1; }

for command in aws jq; do
  command -v "${command}" >/dev/null 2>&1 || { echo "ERROR: required command not found: ${command}" >&2; exit 1; }
done

STAGING="$(mktemp -d)"
trap 'rm -rf "${STAGING}"' EXIT
mkdir -p "${STAGING}/engines"

mapfile -t ACTIVE < <(jq -r 'to_entries[] | select(.value.active != false) | .key' "${DATABASE_DIR}/registry.json")

for engine in "${ACTIVE[@]}"; do
  image="$(grep -E "^${engine}=" "${IMAGES_FILE}" | head -n1 | cut -d'=' -f2- || true)"

  if [[ -z "${image}" ]]; then
    echo "ERROR: ${engine} is active but has no mirrored image in ${IMAGES_FILE}." >&2
    exit 1
  fi

  source_dir="${DATABASE_DIR}/engines/${engine}"
  target_dir="${STAGING}/engines/${engine}"
  mkdir -p "${target_dir}"

  for name in docker-compose.yaml docker-compose.yml; do
    [[ -f "${source_dir}/${name}" ]] && cp "${source_dir}/${name}" "${target_dir}/${name}"
  done

  # sed adds the trailing newline the committed file may lack, so ENGINE_IMAGE
  # can never be glued onto its last line.
  { sed '$a\' "${source_dir}/.env"; printf 'ENGINE_IMAGE=%s\n' "${image}"; } > "${target_dir}/.env"

  echo "Staged ${engine} (${image})."
done

echo "Publishing engine folders to s3://${BUCKET}/database/engines/"
aws s3 sync "${STAGING}/engines/" "s3://${BUCKET}/database/engines/" \
  --delete \
  --only-show-errors \
  --region "${REGION}"

echo "Publishing s3://${BUCKET}/database/registry.json"
aws s3 cp "${DATABASE_DIR}/registry.json" "s3://${BUCKET}/database/registry.json" \
  --content-type application/json \
  --only-show-errors \
  --region "${REGION}"

echo "Published ${#ACTIVE[@]} active engine(s) and the registry."
