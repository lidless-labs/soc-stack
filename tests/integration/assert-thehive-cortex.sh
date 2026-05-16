#!/usr/bin/env bash
# tests/integration/assert-thehive-cortex.sh <result-json>
# Verifies TheHive + Cortex deployment.
#
# Checks:
#   1. Result JSON has thehive-cortex component with status=deployed
#   2. TheHive /api/status returns 2xx/4xx
#   3. Cortex /api/status returns 2xx/4xx
#   4. Both passwords + API keys are non-empty in result JSON

set -euo pipefail

RESULT="${1:-}"
[[ -n "${RESULT}" ]] || { echo "usage: $0 <result-json>" >&2; exit 64; }
[[ -f "${RESULT}" ]] || { echo "result file not found: ${RESULT}" >&2; exit 2; }

log()  { printf '[assert-thc] %s\n' "$*"; }
fail() { printf '[assert-thc] FAIL: %s\n' "$*" >&2; exit 1; }

log "verifying ${RESULT}"

# Check 1: status
status="$(jq -r '.components[] | select(.name == "thehive-cortex") | .status' "${RESULT}")"
[[ "${status}" == "deployed" ]] || fail "thehive-cortex status='${status}', expected 'deployed'"
log "status=deployed"

# Extract URLs and credentials
th_url="$(jq -r '.components[] | select(.name == "thehive-cortex") | .thehive.url // empty' "${RESULT}")"
cx_url="$(jq -r '.components[] | select(.name == "thehive-cortex") | .cortex.url // empty' "${RESULT}")"
th_pw="$(jq -r '.components[] | select(.name == "thehive-cortex") | .thehive.admin_password // empty' "${RESULT}")"
th_key="$(jq -r '.components[] | select(.name == "thehive-cortex") | .thehive.api_key // empty' "${RESULT}")"
cx_pw="$(jq -r '.components[] | select(.name == "thehive-cortex") | .cortex.admin_password // empty' "${RESULT}")"
cx_key="$(jq -r '.components[] | select(.name == "thehive-cortex") | .cortex.api_key // empty' "${RESULT}")"

[[ -n "${th_url}" && -n "${cx_url}" ]] || fail "missing thehive/cortex URLs"
log "thehive.url=${th_url}  cortex.url=${cx_url}"

# Check 4: credentials populated
[[ -n "${th_pw}" && "${th_pw}" != "null" ]]   || fail "thehive admin_password missing in result JSON"
[[ -n "${th_key}" && "${th_key}" != "null" ]]  || fail "thehive api_key missing in result JSON"
[[ -n "${cx_pw}" && "${cx_pw}" != "null" ]]    || fail "cortex admin_password missing in result JSON"
[[ -n "${cx_key}" && "${cx_key}" != "null" ]]  || fail "cortex api_key missing in result JSON"
log "credentials present (thehive pw=${#th_pw} key=${#th_key}, cortex pw=${#cx_pw} key=${#cx_key})"

# Check 2: TheHive /api/status
code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "${th_url}/api/status")"
(( code >= 200 && code < 500 )) || fail "TheHive ${th_url}/api/status -> HTTP ${code}"
log "TheHive ${th_url}/api/status -> HTTP ${code}"

# Check 3: Cortex /api/status
code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "${cx_url}/api/status")"
(( code >= 200 && code < 500 )) || fail "Cortex ${cx_url}/api/status -> HTTP ${code}"
log "Cortex ${cx_url}/api/status -> HTTP ${code}"

log "PASS"
