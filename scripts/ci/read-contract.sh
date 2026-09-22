#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# READ WHAT THIS PIPELINE NEEDS FROM THE PLATFORM CONTRACT
#
# Core publishes /<project>/platform/config. This repository never reads core's
# Terraform state (it holds every secret core generated); the contract has
# everything: the deploy bucket, the database-update document and the ECR
# registry.
#
# Engines run only on the EC2 database host, which only a "shared" environment
# has (development). Anything else fails here rather than half-way through a
# deploy.
#
# Prints KEY=VALUE lines for $GITHUB_ENV:
#   DEPLOY_BUCKET  UPDATE_DOCUMENT  ECR_REGISTRY
#
# Usage: read-contract.sh <project> <aws-region>
# ==============================================================================

PROJECT="${1:?Usage: read-contract.sh <project> <aws-region>}"
REGION="${2:?aws-region is required}"

[[ "${PROJECT}" =~ ^[a-z][a-z0-9-]{1,14}[a-z0-9]$ ]] || { echo "ERROR: '${PROJECT}' is not a project name." >&2; exit 1; }

PARAMETER="/${PROJECT}/platform/config"

if ! CONFIG="$(aws ssm get-parameter --name "${PARAMETER}" --query Parameter.Value --output text --region "${REGION}" 2>&1)"; then
  echo "ERROR: could not read ${PARAMETER}: ${CONFIG}" >&2
  echo "       Has core been applied in this account, and does this role have ssm:GetParameter on it?" >&2
  exit 1
fi

jq -e 'type == "object"' <<< "${CONFIG}" >/dev/null 2>&1 || { echo "ERROR: ${PARAMETER} is not a JSON object." >&2; exit 1; }

VERSION="$(jq -r '.schema_version // empty' <<< "${CONFIG}")"
[[ "${VERSION}" == "1" ]] || { echo "ERROR: this repository was written for platform contract version 1; core publishes '${VERSION}'." >&2; exit 1; }

MODEL="$(jq -r '.hosting_model // empty' <<< "${CONFIG}")"
[[ "${MODEL}" == "shared" ]] || { echo "ERROR: hosting_model is '${MODEL}'. Database engines run only on the EC2 database host of a shared environment (development)." >&2; exit 1; }

DEPLOY_BUCKET="$(jq -r '.buckets.deploy // empty' <<< "${CONFIG}")"
UPDATE_DOCUMENT="$(jq -r '.database.update_document // empty' <<< "${CONFIG}")"
ECR_REGISTRY="$(jq -r '.ecr_registry_url // empty' <<< "${CONFIG}")"

missing=()
[[ -n "${DEPLOY_BUCKET}" ]] || missing+=("buckets.deploy")
[[ -n "${UPDATE_DOCUMENT}" ]] || missing+=("database.update_document (core older than the field?)")
[[ -n "${ECR_REGISTRY}" ]] || missing+=("ecr_registry_url")

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: ${PARAMETER} is missing: ${missing[*]}" >&2
  exit 1
fi

[[ "${DEPLOY_BUCKET}" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || { echo "ERROR: '${DEPLOY_BUCKET}' is not a bucket name." >&2; exit 1; }
[[ "${UPDATE_DOCUMENT}" =~ ^[A-Za-z0-9_.-]{3,128}$ ]] || { echo "ERROR: '${UPDATE_DOCUMENT}' is not a document name." >&2; exit 1; }
[[ "${ECR_REGISTRY}" =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com$ ]] || { echo "ERROR: '${ECR_REGISTRY}' is not an ECR registry." >&2; exit 1; }

echo "DEPLOY_BUCKET=${DEPLOY_BUCKET}"
echo "UPDATE_DOCUMENT=${UPDATE_DOCUMENT}"
echo "ECR_REGISTRY=${ECR_REGISTRY}"
