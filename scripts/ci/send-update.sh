#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# APPLY THE PUBLISHED ENGINES ON THE DATABASE HOST, AND WAIT FOR THE RESULT
#
# Sends core's database-update document, which runs core's update.sh on the
# database host: it syncs what publish-engines.sh uploaded, validates the
# registry, starts every active engine (docker compose up --wait) and stops
# every one marked "active": false.
#
# The document is the only thing this repository's role may send, and only to
# the instance tagged as the database host, so this is not permission to run
# commands there.
#
# A failed update fails the workflow, and the host's output is printed: an engine
# that did not come up would otherwise surface only when a service could not
# provision its database.
#
# Usage: send-update.sh <document> <project> <aws-region>
#
# Environment (all optional):
#   UPDATE_INTERVAL     seconds between checks                  (default 10)
#   UPDATE_TIMEOUT      seconds to wait for it to finish        (default 1500)
#   UPDATE_EMPTY_GRACE  seconds to wait for the host to answer  (default 60)
#   DATABASE_SERVICE_TAG  Service tag of the database host      (default database-hub)
# ==============================================================================

DOCUMENT="${1:?Usage: send-update.sh <document> <project> <aws-region>}"
PROJECT="${2:?project is required}"
REGION="${3:?aws-region is required}"

INTERVAL="${UPDATE_INTERVAL:-10}"
TIMEOUT="${UPDATE_TIMEOUT:-1500}"
EMPTY_GRACE="${UPDATE_EMPTY_GRACE:-60}"

[[ "${DOCUMENT}" =~ ^[A-Za-z0-9_.-]{3,128}$ ]] || { echo "ERROR: '${DOCUMENT}' is not a document name." >&2; exit 1; }
[[ "${PROJECT}" =~ ^[a-z][a-z0-9-]{1,14}[a-z0-9]$ ]] || { echo "ERROR: '${PROJECT}' is not a project name." >&2; exit 1; }

# Core tags the database host with its own service name, and this repository's
# role may send the document only to an instance carrying it.
DATABASE_SERVICE="${DATABASE_SERVICE_TAG:-database-hub}"

echo "Applying the published engines (document ${DOCUMENT})."

if ! COMMAND_ID="$(aws ssm send-command \
    --document-name "${DOCUMENT}" \
    --targets "Key=tag:Project,Values=${PROJECT}" "Key=tag:Service,Values=${DATABASE_SERVICE}" \
    --comment "Apply database engines" \
    --query "Command.CommandId" --output text \
    --region "${REGION}" 2>&1)"; then
  echo "ERROR: could not send the update command: ${COMMAND_ID}" >&2
  exit 1
fi

echo "Command ${COMMAND_ID} sent. Waiting for the database host."

START="${SECONDS}"

while true; do

  INVOCATIONS="$(aws ssm list-command-invocations \
    --command-id "${COMMAND_ID}" --details \
    --query "CommandInvocations[].{id:InstanceId,status:Status,out:CommandPlugins[0].Output}" \
    --output json --region "${REGION}")"

  COUNT="$(jq 'length' <<< "${INVOCATIONS}")"
  ELAPSED=$(( SECONDS - START ))

  if [[ "${COUNT}" -eq 0 ]]; then
    if [[ ${ELAPSED} -ge ${EMPTY_GRACE} ]]; then
      echo "ERROR: the database host did not answer. Is there a running instance tagged Project=${PROJECT} and Service=${DATABASE_SERVICE}?" >&2
      exit 1
    fi
  else
    BUSY="$(jq '[.[] | select(.status == "Pending" or .status == "InProgress" or .status == "Delayed")] | length' <<< "${INVOCATIONS}")"
    [[ "${BUSY}" -eq 0 ]] && break
    echo "  still applying (${ELAPSED}s)."
  fi

  if [[ ${ELAPSED} -ge ${TIMEOUT} ]]; then
    echo "ERROR: the update had not finished after ${TIMEOUT}s; giving up waiting." >&2
    exit 1
  fi

  sleep "${INTERVAL}"

done

FAILED=0

while IFS= read -r invocation; do
  ID="$(jq -r '.id' <<< "${invocation}")"
  STATUS="$(jq -r '.status' <<< "${invocation}")"

  echo
  echo "--- ${ID}: ${STATUS}"
  jq -r '.out // "" | split("\n") | .[-60:] | .[]' <<< "${invocation}" | sed 's/^/    /'

  [[ "${STATUS}" == "Success" ]] || FAILED=$(( FAILED + 1 ))
done < <(jq -c '.[]' <<< "${INVOCATIONS}")

echo

if [[ ${FAILED} -gt 0 ]]; then
  echo "ERROR: the database update did not succeed; see the host's output above." >&2
  exit 1
fi

echo "The database host applied the published engines."
