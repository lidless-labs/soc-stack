#!/usr/bin/env bash
# tests/integration/assert-mcp.sh <result-json>
# Verifies MCP server deployment (9 SSE endpoints on ports 3001-3009).
#
# Checks:
#   1. Result JSON has mcp component with status=deployed
#   2. mcp_endpoints has 9 entries, each with non-empty url and token
#   3. For each of the 9 ports (3001-3009), curl http://<host_ip>:<port>/sse returns 2xx/4xx

set -euo pipefail

RESULT="${1:-}"
[[ -n "${RESULT}" ]] || { echo "usage: $0 <result-json>" >&2; exit 64; }
[[ -f "${RESULT}" ]] || { echo "result file not found: ${RESULT}" >&2; exit 2; }

log()  { printf '[assert-mcp] %s\n' "$*"; }
fail() { printf '[assert-mcp] FAIL: %s\n' "$*" >&2; exit 1; }

log "verifying ${RESULT}"

# Check 1: status
status="$(jq -r '.components[] | select(.name == "mcp") | .status' "${RESULT}")"
[[ "${status}" == "deployed" ]] || fail "mcp status='${status}', expected 'deployed'"
log "status=deployed"

# Extract host_ip
host_ip="$(jq -r '.components[] | select(.name == "mcp") | .host_ip // empty' "${RESULT}")"
[[ -n "${host_ip}" && "${host_ip}" != "null" ]] || fail "host_ip missing in result JSON"
log "host_ip=${host_ip}"

# Check 2: mcp_endpoints has 9 entries with non-empty url and token
endpoint_count="$(jq '.components[] | select(.name == "mcp") | .mcp_endpoints | length' "${RESULT}")"
[[ "${endpoint_count}" -eq 9 ]] || fail "expected 9 mcp_endpoints, got ${endpoint_count}"
log "mcp_endpoints count=${endpoint_count}"

empty_entries="$(jq -r '
  .components[] | select(.name == "mcp") | .mcp_endpoints[] |
  select((.url // "" | length) == 0 or (.token // "" | length) == 0) |
  .name // "unknown"
' "${RESULT}")"
[[ -z "${empty_entries}" ]] || fail "mcp_endpoints with empty url or token: ${empty_entries}"
log "all 9 mcp_endpoints have non-empty url and token"

# Check 3: each port 3001-3009 responds
overall_ok=1
for port in 3001 3002 3003 3004 3005 3006 3007 3008 3009; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://${host_ip}:${port}/sse")"
  if (( code >= 200 && code < 500 )); then
    log "port ${port}/sse -> HTTP ${code}"
  else
    log "FAIL: port ${port}/sse -> HTTP ${code}" >&2
    overall_ok=0
  fi
done

[[ "${overall_ok}" -eq 1 ]] || fail "one or more MCP SSE endpoints returned 5xx or timed out"

log "PASS"
