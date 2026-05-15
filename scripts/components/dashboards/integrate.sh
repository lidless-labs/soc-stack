#!/usr/bin/env bash
# scripts/components/dashboards/integrate.sh
# Runs on the Proxmox HOST. Wires: Zeek log directory -> Dashboards LXC bind-mount
# so Bro Hunter can read live Zeek logs.

set -euo pipefail

: "${SOC_STATE_DIR:?SOC_STATE_DIR must be set}"

log() { printf '[dash-integrate] %s\n' "$*"; }

DASH_STATE="${SOC_STATE_DIR}/state/dashboards.json"
[[ -f "${DASH_STATE}" ]] || { log "dashboards state missing, skipping"; exit 0; }
[[ "$(jq -r '.status' "${DASH_STATE}")" == "deployed" ]] || { log "not deployed, skipping"; exit 0; }

dash_vmid="$(jq -r '.lxc.vmid // empty' "${DASH_STATE}")"
[[ -n "${dash_vmid}" ]] || { log "no dashboards VMID, skipping"; exit 0; }

# Check if zeek-suricata state is available and deployed
ZS_STATE="${SOC_STATE_DIR}/state/zeek-suricata.json"
if [[ ! -f "${ZS_STATE}" ]] || [[ "$(jq -r '.status' "${ZS_STATE}")" != "deployed" ]]; then
  log "Zeek logs unavailable, Bro Hunter will run without live data"
  exit 0
fi

zeek_vmid="$(jq -r '.lxc.vmid // empty' "${ZS_STATE}")"
if [[ -z "${zeek_vmid}" ]]; then
  log "Zeek logs unavailable, Bro Hunter will run without live data"
  exit 0
fi

ZEEK_LOG_SOURCE="/var/lib/lxc/${zeek_vmid}/rootfs/opt/zeek/logs"
ZEEK_LOG_MOUNT="/opt/s3-dashboards/zeek-logs"

# Check if mount point already configured on the dashboards LXC
if pct config "${dash_vmid}" 2>/dev/null | grep -q "mp0:"; then
  log "bind-mount mp0 already configured on dashboards LXC ${dash_vmid}, skipping"
  exit 0
fi

log "configuring read-only Zeek log bind-mount from LXC ${zeek_vmid} to LXC ${dash_vmid}"
pct set "${dash_vmid}" \
  -mp0 "${ZEEK_LOG_SOURCE},mp=${ZEEK_LOG_MOUNT},ro=1"

log "Zeek log bind-mount configured (${ZEEK_LOG_SOURCE} -> ${ZEEK_LOG_MOUNT} ro)"
log "dashboards integration phase complete"
