#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# MIRROR EACH ACTIVE ENGINE'S IMAGE INTO THIS ACCOUNT'S ECR
#
# The database host sits in the isolated tier, with no internet path, and core
# rejects any image that is not from this account's ECR registry. So every
# engine image is copied here first.
#
# image.json names an upstream tag ("postgres:17"). It is resolved to a digest
# at mirror time, and the ECR tag carries both the platform and that digest:
#
#   <registry>/engines/postgres:17-amd64-<first 12 of the digest>
#
# The ECR repository is tag-immutable, so a tag always means one image, and a
# tag that already exists is not copied again. A series tag such as "17" picks
# up upstream patch releases on the next deploy (which restarts that engine);
# pin an exact tag in image.json to hold a version.
#
# Only active engines are mirrored: an inactive one is never started.
#
# Writes one line per mirrored engine to <images-file>:
#   <engine>=<registry>/engines/<engine>:<tag>
#
# Usage: mirror-images.sh <database-dir> <ecr-registry> <aws-region> <images-file>
#
# Environment (optional):
#   IMAGE_REPOSITORY_PREFIX  ECR repository prefix core's engines role may use
#                            (default "engines")
# ==============================================================================

DATABASE_DIR="${1:?Usage: mirror-images.sh <database-dir> <ecr-registry> <aws-region> <images-file>}"
REGISTRY_URL="${2:?ecr-registry is required}"
REGION="${3:?aws-region is required}"
IMAGES_FILE="${4:?images-file is required}"

PREFIX="${IMAGE_REPOSITORY_PREFIX:-engines}"
DATABASE_DIR="${DATABASE_DIR%/}"

[[ "${REGISTRY_URL}" =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com$ ]] || { echo "ERROR: '${REGISTRY_URL}' is not an ECR registry." >&2; exit 1; }

for command in aws docker jq; do
  command -v "${command}" >/dev/null 2>&1 || { echo "ERROR: required command not found: ${command}" >&2; exit 1; }
done

: > "${IMAGES_FILE}"

mapfile -t ACTIVE < <(jq -r 'to_entries[] | select(.value.active != false) | .key' "${DATABASE_DIR}/registry.json")

if [[ ${#ACTIVE[@]} -eq 0 ]]; then
  echo "No active engines; nothing to mirror."
  exit 0
fi

echo "Logging in to ${REGISTRY_URL}."
aws ecr get-login-password --region "${REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY_URL}" >/dev/null

for engine in "${ACTIVE[@]}"; do
  image_json="${DATABASE_DIR}/engines/${engine}/image.json"
  source_ref="$(jq -r '.source' "${image_json}")"
  platform="$(jq -r '.platform' "${image_json}")"

  repository="${PREFIX}/${engine}"

  echo "== ${engine}: ${source_ref} (${platform})"

  if ! digest="$(docker buildx imagetools inspect "${source_ref}" --format '{{json .Manifest}}' 2>&1 | jq -er '.digest')"; then
    echo "ERROR: could not resolve ${source_ref} to a digest. Does the tag exist?" >&2
    exit 1
  fi

  [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "ERROR: '${digest}' is not a sha256 digest." >&2; exit 1; }

  tag="${source_ref##*:}-${platform##*/}-${digest:7:12}"
  target="${REGISTRY_URL}/${repository}:${tag}"

  if ! aws ecr describe-repositories --repository-names "${repository}" --region "${REGION}" >/dev/null 2>&1; then
    echo "   creating ECR repository ${repository}"
    aws ecr create-repository \
      --repository-name "${repository}" \
      --image-tag-mutability IMMUTABLE \
      --image-scanning-configuration scanOnPush=true \
      --region "${REGION}" >/dev/null
  fi

  if aws ecr describe-images --repository-name "${repository}" --image-ids "imageTag=${tag}" --region "${REGION}" >/dev/null 2>&1; then
    echo "   already mirrored as ${tag}"
  else
    echo "   copying ${digest} as ${tag}"
    docker pull --quiet --platform "${platform}" "${source_ref%:*}@${digest}" >/dev/null
    docker tag "${source_ref%:*}@${digest}" "${target}"
    docker push --quiet "${target}" >/dev/null
  fi

  printf '%s=%s\n' "${engine}" "${target}" >> "${IMAGES_FILE}"
done

echo "Mirrored ${#ACTIVE[@]} engine image(s)."
