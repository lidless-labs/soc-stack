#!/usr/bin/env bash
# tests/integration/assert-misp.sh <result-json>
# Verifies MISP deployment.
#
# Checks:
#   1. Result JSON has misp component with status=deployed
#   2. https://<ip>/users/heartbeat returns 2xx/4xx (-k for self-signed cert)
#   3. admin_password and api_key are non-empty in result JSON

set -euo pipefail

RESULT="${1:-}"
[[ -n "${RESULT}" ]] || { echo "usage: $0 <result-json>" >&2; exit 64; }
[[ -f "${RESULT}" ]] || { echo "result file not found: ${RESULT}" >&2; exit 2; }

log()  { printf '[assert-misp] %s\n' "$*"; }
fail() { printf '[assert-misp] FAIL: %s\n' "$*" >&2; exit 1; }

log "verifying ${RESULT}"

# Check 1: status
status="$(jq -r '.components[] | select(.name == "misp") | .status' "${RESULT}")"
[[ "${status}" == "deployed" ]] || fail "misp status='${status}', expected 'deployed'"
log "status=deployed"

# Extract URL and credentials
url="$(jq -r '.components[] | select(.name == "misp") | .url // empty' "${RESULT}")"
admin_pw="$(jq -r '.components[] | select(.name == "misp") | .admin_password // empty' "${RESULT}")"
api_key="$(jq -r '.components[] | select(.name == "misp") | .api_key // empty' "${RESULT}")"

[[ -n "${url}" ]] || fail "misp URL missing in result JSON"
log "url=${url}"

# Check 3: credentials populated
[[ -n "${admin_pw}" && "${admin_pw}" != "null" ]] || fail "admin_password missing in result JSON"
[[ -n "${api_key}" && "${api_key}" != "null" ]]   || fail "api_key missing in result JSON"
log "credentials present (pw=${#admin_pw} key=${#api_key})"

# Check 2: heartbeat endpoint (-k for self-signed cert)
code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "${url}/users/heartbeat")"
(( code >= 200 && code < 500 )) || fail "MISP ${url}/users/heartbeat -> HTTP ${code}"
log "MISP ${url}/users/heartbeat -> HTTP ${code}"

log "PASS"
