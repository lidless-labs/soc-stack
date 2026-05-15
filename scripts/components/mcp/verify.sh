#!/usr/bin/env bash
# scripts/components/mcp/verify.sh
# Runs INSIDE the mcp LXC. Exit 0 if healthy.

set -euo pipefail

fail=0

servers=(wazuh thehive cortex misp zeek suricata mitre rapid7 sophos)
ports=(3001 3002 3003 3004 3005 3006 3007 3008 3009)

for s in "${servers[@]}"; do
  if ! systemctl is-active --quiet "soc-mcp-${s}.service"; then
    printf '[verify] soc-mcp-%s.service not active\n' "${s}" >&2
    fail=1
  fi
done

for p in "${ports[@]}"; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:${p}/sse" || echo 000)"
  if [[ "${code}" == "000" ]] || (( code >= 500 )); then
    printf '[verify] port %s: code=%s\n' "${p}" "${code}" >&2
    fail=1
  fi
done

exit "${fail}"
