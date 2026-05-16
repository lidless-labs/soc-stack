#!/usr/bin/env bash
# scripts/components/dashboards/destroy.sh
# Runs on Proxmox HOST. Tears down the dashboards LXC + removes state file.

set -euo pipefail

: "${SOC_STATE_DIR:?SOC_STATE_DIR must be set}"

STATE_FILE="${SOC_STATE_DIR}/state/dashboards.json"
log() { printf '[dash-destroy] %s\n' "$*"; }

if [[ ! -f "${STATE_FILE}" ]]; then
  log "no state file, nothing to destroy"; exit 0
fi

VMID="$(jq -r '.lxc.vmid // empty' "${STATE_FILE}")"
if [[ -z "${VMID}" ]]; then
  log "no VMID, removing state only"; rm -f "${STATE_FILE}"; exit 0
fi

pct stop "${VMID}" 2>/dev/null || true
pct destroy "${VMID}" 2>/dev/null || true
rm -f "${STATE_FILE}"
log "dashboards teardown complete (VMID ${VMID})"
