#!/usr/bin/env bash
# scripts/components/wazuh/destroy.sh
# Runs on the Proxmox HOST. Tears down the Wazuh LXC.
#
# Required env:
#   SOC_STATE_DIR

set -euo pipefail

: "${SOC_STATE_DIR:?SOC_STATE_DIR must be set}"

STATE_FILE="${SOC_STATE_DIR}/state/wazuh.json"
log() { printf '[wazuh-destroy] %s\n' "$*"; }

if [[ ! -f "${STATE_FILE}" ]]; then
  log "no state file for wazuh, nothing to destroy"
  exit 0
fi

VMID="$(jq -r '.lxc.vmid // empty' "${STATE_FILE}")"
if [[ -z "${VMID}" ]]; then
  log "no VMID in wazuh state, removing state file only"
  rm -f "${STATE_FILE}"
  exit 0
fi

log "stopping LXC ${VMID}"
pct stop "${VMID}" 2>/dev/null || true
log "destroying LXC ${VMID}"
pct destroy "${VMID}" 2>/dev/null || true

rm -f "${STATE_FILE}"
log "wazuh teardown complete"
