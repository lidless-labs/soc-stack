#!/usr/bin/env bash
# scripts/components/mcp/destroy.sh
# Runs on the Proxmox HOST. Tears down the mcp LXC and removes state.

set -euo pipefail

: "${SOC_STATE_DIR:?SOC_STATE_DIR must be set}"

STATE_FILE="${SOC_STATE_DIR}/state/mcp.json"
log() { printf '[mcp-destroy] %s\n' "$*"; }

if [[ ! -f "${STATE_FILE}" ]]; then
  log "no state file for mcp, nothing to destroy"
  exit 0
fi

VMID="$(jq -r '.lxc.vmid // empty' "${STATE_FILE}")"
if [[ -z "${VMID}" ]]; then
  log "no VMID in mcp state, removing state file only"
  rm -f "${STATE_FILE}"
  exit 0
fi

log "stopping LXC ${VMID}"
pct stop "${VMID}" 2>/dev/null || true
log "destroying LXC ${VMID}"
pct destroy "${VMID}" 2>/dev/null || true

rm -f "${STATE_FILE}"
log "mcp teardown complete (VMID ${VMID})"
