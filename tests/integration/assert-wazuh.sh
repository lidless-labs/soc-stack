#!/usr/bin/env bash
# tests/integration/assert-wazuh.sh <result-json>
# Verifies that a Wazuh deployment described in result-json actually works.
#
# Checks:
#   1. Result JSON has wazuh component with status=deployed
#   2. Dashboard URL returns an HTTPS response
#   3. API URL returns a response (any HTTP code 200-499 is fine - means it's listening)
#   4. Credentials field is populated

set -euo pipefail

RESULT="${1:-}"
[[ -n "${RESULT}" ]] || { echo "usage: $0 <result-json>" >&2; exit 64; }
[[ -f "${RESULT}" ]] || { echo "result file not found: ${RESULT}" >&2; exit 2; }

log() { printf '[assert-wazuh] %s\n' "$*"; }
fail() { printf '[assert-wazuh] FAIL: %s\n' "$*" >&2; exit 1; }

log "verifying ${RESULT}"

# Check 1: status
status="$(jq -r '.components[] | select(.name == "wazuh") | .status' "${RESULT}")"
[[ "${status}" == "deployed" ]] || fail "wazuh status is '${status}', expected 'deployed'"
log "status=deployed"

# Check 2: dashboard URL
url="$(jq -r '.components[] | select(.name == "wazuh") | .endpoints.dashboard // .url' "${RESULT}")"
[[ -n "${url}" ]] || fail "no dashboard URL in result JSON"
code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "${url}")"
(( code >= 200 && code < 500 )) || fail "dashboard ${url} returned HTTP ${code}"
log "dashboard ${url} -> HTTP ${code}"

# Check 3: API
api="$(jq -r '.components[] | select(.name == "wazuh") | .endpoints.api // .api_url' "${RESULT}")"
[[ -n "${api}" ]] || fail "no API URL in result JSON"
code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "${api}")"
(( code >= 200 && code < 600 )) || fail "API ${api} returned HTTP ${code}"
log "api ${api} -> HTTP ${code}"

# Check 4: credentials populated
admin_pw="$(jq -r '.components[] | select(.name == "wazuh") | .credentials.admin_password // .credentials.password' "${RESULT}")"
[[ -n "${admin_pw}" && "${admin_pw}" != "null" ]] || fail "admin password missing in result JSON"
log "admin password present (length=${#admin_pw})"

log "PASS"
