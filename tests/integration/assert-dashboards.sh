#!/usr/bin/env bash
# tests/integration/assert-dashboards.sh <result-json>
# Verifies dashboards deployment (Bro Hunter + Playbook Forge).
#
# Checks:
#   1. Result JSON has dashboards component with status=deployed
#   2. http://<host_ip>/bro-hunter/ returns 2xx/3xx
#   3. http://<host_ip>/playbook-forge/ returns 2xx/3xx

set -euo pipefail

RESULT="${1:-}"
[[ -n "${RESULT}" ]] || { echo "usage: $0 <result-json>" >&2; exit 64; }
[[ -f "${RESULT}" ]] || { echo "result file not found: ${RESULT}" >&2; exit 2; }

log()  { printf '[assert-dash] %s\n' "$*"; }
fail() { printf '[assert-dash] FAIL: %s\n' "$*" >&2; exit 1; }

log "verifying ${RESULT}"

# Check 1: status
status="$(jq -r '.components[] | select(.name == "dashboards") | .status' "${RESULT}")"
[[ "${status}" == "deployed" ]] || fail "dashboards status='${status}', expected 'deployed'"
log "status=deployed"

# Extract host IP
host_ip="$(jq -r '.components[] | select(.name == "dashboards") | .host_ip // .lxc.ip // empty' "${RESULT}")"
[[ -n "${host_ip}" && "${host_ip}" != "null" ]] || fail "host_ip missing in result JSON"
log "host_ip=${host_ip}"

# Check 2: Bro Hunter
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://${host_ip}/bro-hunter/")"
(( code >= 200 && code < 400 )) || fail "Bro Hunter http://${host_ip}/bro-hunter/ -> HTTP ${code}"
log "Bro Hunter http://${host_ip}/bro-hunter/ -> HTTP ${code}"

# Check 3: Playbook Forge
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://${host_ip}/playbook-forge/")"
(( code >= 200 && code < 400 )) || fail "Playbook Forge http://${host_ip}/playbook-forge/ -> HTTP ${code}"
log "Playbook Forge http://${host_ip}/playbook-forge/ -> HTTP ${code}"

log "PASS"
