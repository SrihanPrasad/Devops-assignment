#!/usr/bin/env bash
# =============================================================================
# TASK 5 - SonarQube scan using a *dynamic* token
#
#   1. Uses an ADMIN credential (SONAR_ADMIN_TOKEN) only to mint a new token
#   2. The minted token is of type PROJECT_ANALYSIS_TOKEN
#        -> can only run analysis on ONE project (SONAR_PROJECT_KEY), nothing else
#   3. It is created with an expiration date of "now + 24h"
#   4. The scan runs with that token (passed via env, never on the command line)
#   5. The token is revoked right after the scan (trap), so in practice it
#      lives for minutes; the 24h expiry is the safety net if the script dies
#
# Required env:
#   SONAR_HOST_URL      e.g. http://localhost:9000
#   SONAR_ADMIN_TOKEN   user token of a user allowed to run analysis on the project
#                       (Execute Analysis permission) - used ONLY to create/revoke
#   SONAR_PROJECT_KEY   project to scan (created automatically if missing)
# Optional env:
#   SOURCE_DIR          directory to scan (default: current dir)
#   TOKEN_TTL_HOURS     informational; SonarQube expiry is date-based (default 24)
#   KEEP_TOKEN=1        do not revoke after the scan
#
# Usage:  SONAR_HOST_URL=... SONAR_ADMIN_TOKEN=... SONAR_PROJECT_KEY=demo-app \
#         ./scripts/sonar-scan.sh [source_dir]
# Needs:  curl, jq   (+ mvn, sonar-scanner, or docker for the scan itself)
# =============================================================================
set -euo pipefail

: "${SONAR_HOST_URL:?set SONAR_HOST_URL}"
: "${SONAR_ADMIN_TOKEN:?set SONAR_ADMIN_TOKEN}"
: "${SONAR_PROJECT_KEY:?set SONAR_PROJECT_KEY}"
SONAR_HOST_URL="${SONAR_HOST_URL%/}"
SOURCE_DIR="${1:-${SOURCE_DIR:-$PWD}}"

for bin in curl jq; do
  command -v "$bin" >/dev/null || { echo "ERROR: $bin is required" >&2; exit 1; }
done

log() { printf '[sonar-scan] %s\n' "$*"; }

# curl wrapper for the admin credential. Token goes via -u (basic auth, empty password).
sonar_api() {
  local method="$1" path="$2"; shift 2
  curl -sS -f -X "$method" -u "${SONAR_ADMIN_TOKEN}:" "${SONAR_HOST_URL}${path}" "$@"
}

# --- 0. server reachable? -----------------------------------------------------
status="$(curl -sS -f "${SONAR_HOST_URL}/api/system/status" | jq -r .status || true)"
[ "$status" = "UP" ] || { echo "ERROR: SonarQube at $SONAR_HOST_URL is not UP (status='$status')" >&2; exit 1; }

# --- 1. make sure the project exists ------------------------------------------
found="$(sonar_api GET "/api/projects/search?projects=${SONAR_PROJECT_KEY}" | jq -r '.paging.total')"
if [ "$found" = "0" ]; then
  log "project '${SONAR_PROJECT_KEY}' not found - creating it"
  sonar_api POST "/api/projects/create" \
    --data-urlencode "project=${SONAR_PROJECT_KEY}" \
    --data-urlencode "name=${SONAR_PROJECT_KEY}" >/dev/null
fi

# --- 2. mint the dynamic token -------------------------------------------------
# SonarQube expiry is a calendar date (UTC). "tomorrow" == at most ~24h from now.
expiry="$(date -u -d '+1 day' +%F 2>/dev/null || date -u -v+1d +%F)"
token_name="scan-${SONAR_PROJECT_KEY}-$(date -u +%Y%m%dT%H%M%SZ)-$$"

log "creating PROJECT_ANALYSIS_TOKEN '${token_name}' for project '${SONAR_PROJECT_KEY}', expires ${expiry}"
resp="$(sonar_api POST "/api/user_tokens/generate" \
          --data-urlencode "name=${token_name}" \
          --data-urlencode "type=PROJECT_ANALYSIS_TOKEN" \
          --data-urlencode "projectKey=${SONAR_PROJECT_KEY}" \
          --data-urlencode "expirationDate=${expiry}")"

SONAR_TOKEN="$(jq -r .token <<<"$resp")"
[ -n "$SONAR_TOKEN" ] && [ "$SONAR_TOKEN" != "null" ] || { echo "ERROR: token generation failed" >&2; exit 1; }
log "token created (type=$(jq -r .type <<<"$resp"), expiration=$(jq -r .expirationDate <<<"$resp"))"

revoke_token() {
  if [ "${KEEP_TOKEN:-0}" = "1" ]; then
    log "KEEP_TOKEN=1 - leaving token '${token_name}' in place (expires ${expiry})"
    return
  fi
  log "revoking token '${token_name}'"
  sonar_api POST "/api/user_tokens/revoke" --data-urlencode "name=${token_name}" >/dev/null \
    || log "WARNING: could not revoke token (it will still expire on ${expiry})"
}
trap revoke_token EXIT

# --- 3. run the scan with the dynamic token -----------------------------------
export SONAR_HOST_URL SONAR_TOKEN          # scanners read these env vars natively
cd "$SOURCE_DIR"

if [ -f pom.xml ]; then
  log "Maven project detected - running sonar-maven-plugin"
  mvn -B -ntp org.sonarsource.scanner.maven:sonar-maven-plugin:4.0.0.4121:sonar \
      -Dsonar.projectKey="${SONAR_PROJECT_KEY}" \
      -Dsonar.qualitygate.wait=true ${MVN_ARGS:-}
elif command -v sonar-scanner >/dev/null; then
  log "running sonar-scanner CLI"
  sonar-scanner -Dsonar.projectKey="${SONAR_PROJECT_KEY}" -Dsonar.qualitygate.wait=true
else
  command -v docker >/dev/null || { echo "ERROR: need mvn, sonar-scanner or docker" >&2; exit 1; }
  log "running sonar-scanner in Docker"
  docker run --rm --network host -e SONAR_HOST_URL -e SONAR_TOKEN \
    -v "$PWD:/usr/src" sonarsource/sonar-scanner-cli \
    -Dsonar.projectKey="${SONAR_PROJECT_KEY}" -Dsonar.qualitygate.wait=true
fi

log "scan finished OK"
