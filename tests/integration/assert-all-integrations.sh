#!/usr/bin/env bash
# tests/integration/assert-all-integrations.sh <result-json>
# Verifies cross-component wiring actually flows.
#
# Integrations checked:
#   1. Wazuh -> TheHive: ossec.conf has custom-thehive integration
#   2. TheHive <-> Cortex: /api/v1/config/cortex returns S3-CORTEX entry
#   3. MISP -> Suricata: /etc/suricata/update.d/misp.conf + /etc/cron.d/s3-misp-rules exist
#   4. Zeek -> Wazuh: wazuh-agent systemd unit active in zeek-suricata LXC
#   5. MCP env files populated: /etc/soc-mcp/{wazuh,thehive,cortex,misp,zeek,suricata}.env non-empty
#
# Requires: pct (must run on Proxmox host)

set -euo pipefail

RESULT="${1:-}"
[[ -n "${RESULT}" ]] || { echo "usage: $0 <result-json>" >&2; exit 64; }
[[ -f "${RESULT}" ]] || { echo "result file not found: ${RESULT}" >&2; exit 2; }
command -v pct >/dev/null 2>&1 || { echo "pct not available (run on Proxmox host)" >&2; exit 3; }

passes=0
fails=0

mark_pass() { printf '[PASS] %s\n' "$*"; passes=$(( passes + 1 )); }
mark_fail() { printf '[FAIL] %s\n' "$*" >&2; fails=$(( fails + 1 )); }

# Resolve VMIDs from result JSON
get_vmid() {
  jq -r --arg n "$1" '.components[] | select(.name == $n) | .lxc.vmid // empty' "${RESULT}"
}

wazuh_vmid="$(get_vmid wazuh)"
zs_vmid="$(get_vmid zeek-suricata)"
mcp_vmid="$(get_vmid mcp)"

th_url="$(jq -r '.components[] | select(.name == "thehive-cortex") | .thehive.url // empty' "${RESULT}")"
th_key="$(jq -r '.components[] | select(.name == "thehive-cortex") | .thehive.api_key // empty' "${RESULT}")"

# -----------------------------------------------------------------------
# 1. Wazuh -> TheHive: ossec.conf has the custom integration stanza
# -----------------------------------------------------------------------
if [[ -n "${wazuh_vmid}" ]] \
   && pct exec "${wazuh_vmid}" -- grep -q custom-thehive /var/ossec/etc/ossec.conf 2>/dev/null; then
  mark_pass "Wazuh -> TheHive webhook (ossec.conf)"
else
  mark_fail "Wazuh -> TheHive webhook (ossec.conf missing or wazuh vmid missing)"
fi

# -----------------------------------------------------------------------
# 2. TheHive <-> Cortex: config endpoint lists S3-CORTEX
# -----------------------------------------------------------------------
if [[ -n "${th_url}" && -n "${th_key}" ]]; then
  body="$(curl -sk -H "Authorization: Bearer ${th_key}" \
    --max-time 10 "${th_url}/api/v1/config/cortex" 2>/dev/null || echo "")"
  if grep -q 'S3-CORTEX' <<< "${body}"; then
    mark_pass "TheHive <-> Cortex link configured"
  else
    mark_fail "TheHive <-> Cortex link not configured (S3-CORTEX not found in config)"
  fi
else
  mark_fail "TheHive URL/key missing in result JSON"
fi

# -----------------------------------------------------------------------
# 3. MISP -> Suricata: rule feed files exist in zeek-suricata LXC
# -----------------------------------------------------------------------
if [[ -n "${zs_vmid}" ]] \
   && pct exec "${zs_vmid}" -- test -f /etc/suricata/update.d/misp.conf 2>/dev/null \
   && pct exec "${zs_vmid}" -- test -f /etc/cron.d/s3-misp-rules 2>/dev/null; then
  mark_pass "MISP -> Suricata rule feed"
else
  mark_fail "MISP -> Suricata rule feed not configured (files missing or zeek-suricata vmid missing)"
fi

# -----------------------------------------------------------------------
# 4. Zeek -> Wazuh: wazuh-agent active in zeek-suricata LXC
# -----------------------------------------------------------------------
if [[ -n "${zs_vmid}" ]] \
   && pct exec "${zs_vmid}" -- systemctl is-active --quiet wazuh-agent 2>/dev/null; then
  mark_pass "Zeek -> Wazuh agent forward"
else
  mark_fail "Zeek -> Wazuh agent not active in LXC ${zs_vmid:-<missing>}"
fi

# -----------------------------------------------------------------------
# 5. MCP env files populated for each peer service
# -----------------------------------------------------------------------
if [[ -n "${mcp_vmid}" ]]; then
  envs_ok=1
  for srv in wazuh thehive cortex misp zeek suricata; do
    if ! pct exec "${mcp_vmid}" -- bash -c \
         "test -f /etc/soc-mcp/${srv}.env && grep -E '^[A-Z_]+=.+' /etc/soc-mcp/${srv}.env >/dev/null" \
         2>/dev/null; then
      envs_ok=0
      break
    fi
  done
  if [[ "${envs_ok}" -eq 1 ]]; then
    mark_pass "MCP env files populated (wazuh,thehive,cortex,misp,zeek,suricata)"
  else
    mark_fail "MCP env files missing or empty in LXC ${mcp_vmid}"
  fi
else
  mark_fail "MCP VMID missing in result JSON"
fi

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
echo ""
printf 'integrations: %d pass, %d fail\n' "${passes}" "${fails}"
[[ "${fails}" -eq 0 ]]
