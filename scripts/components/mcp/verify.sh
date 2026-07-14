#!/usr/bin/env bash
# scripts/components/mcp/verify.sh
# Runs INSIDE the mcp LXC. Exit 0 if healthy.

set -euo pipefail

fail=0

servers=(wazuh thehive cortex misp zeek suricata mitre rapid7 sophos)

# MCP services need integration env vars (WAZUH_URL etc.) before they can
# stay up. At initial deploy, they crash-loop on missing required vars.
# Verify that units are enabled (registered) - activation happens post-integrate.
for s in "${servers[@]}"; do
  if ! systemctl is-enabled --quiet "soc-mcp-${s}.service" 2>/dev/null; then
    printf '[verify] soc-mcp-%s.service not enabled\n' "${s}" >&2
    fail=1
  fi
done

# Ports will be unreachable until integrate.sh populates env vars; skip port check here.

# The nginx auth gateway fronts every endpoint and enforces the bearer token.
# If it is down or misconfigured the endpoints are unreachable or unauthenticated.
if ! systemctl is-enabled --quiet nginx 2>/dev/null; then
  printf '[verify] nginx (MCP auth gateway) not enabled\n' >&2
  fail=1
fi
if ! nginx -t >/dev/null 2>&1; then
  printf '[verify] nginx config failed validation\n' >&2
  fail=1
fi

exit "${fail}"
