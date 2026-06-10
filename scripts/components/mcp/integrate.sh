#!/usr/bin/env bash
# scripts/components/mcp/integrate.sh
# Runs on the Proxmox HOST. Reads peer component state, populates each
# MCP server's environment file, restarts each service.

set -euo pipefail
: "${SOC_STATE_DIR:?}"
log() { printf '[mcp-integrate] %s\n' "$*"; }

MCP_STATE="${SOC_STATE_DIR}/state/mcp.json"
[[ -f "${MCP_STATE}" ]] || { log "mcp state missing, skipping"; exit 0; }
mcp_status="$(jq -r '.status // empty' "${MCP_STATE}")"
[[ "${mcp_status}" == "deployed" ]] || { log "mcp status=${mcp_status}, skipping"; exit 0; }

mcp_vmid="$(jq -r '.lxc.vmid // empty' "${MCP_STATE}")"
[[ -n "${mcp_vmid}" ]] || { log "mcp has no VMID"; exit 0; }

# Temp files hold credentials; make sure they vanish even if a pct call dies.
TMP_CLEANUP=()
trap '[[ ${#TMP_CLEANUP[@]} -gt 0 ]] && rm -f "${TMP_CLEANUP[@]}"' EXIT

write_env() {
  local server="$1"; shift
  # remaining args are KEY=value pairs
  local env_file="/etc/soc-mcp/${server}.env"
  local tmp
  tmp="$(mktemp)"
  TMP_CLEANUP+=("${tmp}")
  pct exec "${mcp_vmid}" -- cat "${env_file}" > "${tmp}" 2>/dev/null || true
  # Rebuild line-by-line instead of sed: credential values must never be
  # interpolated into a sed expression (delimiters/backrefs corrupt the file).
  local kv key
  for kv in "$@"; do
    key="${kv%%=*}"
    if grep -q "^${key}=" "${tmp}"; then
      grep -v "^${key}=" "${tmp}" > "${tmp}.new" || true
      mv "${tmp}.new" "${tmp}"
    fi
    printf '%s\n' "${kv}" >> "${tmp}"
  done
  pct push "${mcp_vmid}" "${tmp}" "${env_file}"
  pct exec "${mcp_vmid}" -- chmod 600 "${env_file}"
  pct exec "${mcp_vmid}" -- systemctl restart "soc-mcp-${server}.service"
  rm -f "${tmp}"
}

# --- wazuh ---
ws="${SOC_STATE_DIR}/state/wazuh.json"
if [[ -f "${ws}" ]] && [[ "$(jq -r '.status' "${ws}")" == "deployed" ]]; then
  url="$(jq -r '.api_url' "${ws}")"
  pw="$(jq -r '.credentials.password' "${ws}")"
  write_env wazuh "WAZUH_URL=${url}" "WAZUH_USER=admin" "WAZUH_PASSWORD=${pw}"
  log "wired wazuh-mcp"
fi

# --- thehive + cortex ---
ts="${SOC_STATE_DIR}/state/thehive-cortex.json"
if [[ -f "${ts}" ]] && [[ "$(jq -r '.status' "${ts}")" == "deployed" ]]; then
  thu="$(jq -r '.thehive.url' "${ts}")"
  thk="$(jq -r '.thehive.api_key' "${ts}")"
  write_env thehive "THEHIVE_URL=${thu}" "THEHIVE_API_KEY=${thk}"
  log "wired thehive-mcp"

  cxu="$(jq -r '.cortex.url' "${ts}")"
  cxk="$(jq -r '.cortex.api_key' "${ts}")"
  write_env cortex "CORTEX_URL=${cxu}" "CORTEX_API_KEY=${cxk}"
  log "wired cortex-mcp"
fi

# --- misp ---
ms="${SOC_STATE_DIR}/state/misp.json"
if [[ -f "${ms}" ]] && [[ "$(jq -r '.status' "${ms}")" == "deployed" ]]; then
  url="$(jq -r '.url' "${ms}")"
  key="$(jq -r '.api_key' "${ms}")"
  write_env misp "MISP_URL=${url}" "MISP_API_KEY=${key}"
  log "wired misp-mcp"
fi

# --- zeek + suricata (log-based) ---
zs="${SOC_STATE_DIR}/state/zeek-suricata.json"
if [[ -f "${zs}" ]] && [[ "$(jq -r '.status' "${zs}")" == "deployed" ]]; then
  # Note: zeek and suricata MCP servers run on the mcp LXC and read LOCAL log files.
  # They need a bind-mount or NFS to the zeek-suricata LXC's log dirs. For Plan 2,
  # we set the env path; Plan 3 wires the actual bind-mount.
  zlog="$(jq -r '.zeek.log_dir' "${zs}")"
  write_env zeek "ZEEK_LOG_DIR=${zlog}" "ZEEK_LOG_FORMAT=json"
  log "wired zeek-mcp (path-only; bind-mount in Plan 3)"

  evepath="$(jq -r '.suricata.eve_path' "${zs}")"
  write_env suricata "SURICATA_EVE_PATH=${evepath}"
  log "wired suricata-mcp (path-only; bind-mount in Plan 3)"
fi

# --- mitre (no peer; just confirm env exists) ---
write_env mitre "MITRE_DATA_DIR=/opt/soc-mcp/mitre-mcp/data"
log "wired mitre-mcp"

# --- rapid7 + sophos: only wire if user supplied creds via env on the host ---
# These are commercial APIs; users provide creds via /etc/soc-stack/rapid7.env or sophos.env
if [[ -f /etc/soc-stack/rapid7.env ]]; then
  # shellcheck disable=SC1091
  . /etc/soc-stack/rapid7.env
  write_env rapid7 "RAPID7_URL=${RAPID7_URL:-}" "RAPID7_API_KEY=${RAPID7_API_KEY:-}"
  log "wired rapid7-mcp from /etc/soc-stack/rapid7.env"
fi
if [[ -f /etc/soc-stack/sophos.env ]]; then
  # shellcheck disable=SC1091
  . /etc/soc-stack/sophos.env
  write_env sophos "SOPHOS_CLIENT_ID=${SOPHOS_CLIENT_ID:-}" "SOPHOS_CLIENT_SECRET=${SOPHOS_CLIENT_SECRET:-}"
  log "wired sophos-mcp from /etc/soc-stack/sophos.env"
fi

log "mcp integration phase complete"
