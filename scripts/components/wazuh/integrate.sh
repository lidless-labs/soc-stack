#!/usr/bin/env bash
# scripts/components/wazuh/integrate.sh
# Runs on the Proxmox HOST after all components are deployed.
# Wires Wazuh to other components based on their state files.
#
# Plan 1: stub. Plan 2 adds TheHive webhook wiring.

set -euo pipefail

: "${SOC_STATE_DIR:?SOC_STATE_DIR must be set}"

log() { printf '[wazuh-integrate] %s\n' "$*"; }

THEHIVE_STATE="${SOC_STATE_DIR}/state/thehive-cortex.json"

if [[ ! -f "${THEHIVE_STATE}" ]]; then
  log "TheHive not deployed, skipping Wazuh -> TheHive webhook wiring"
  exit 0
fi

thehive_status="$(jq -r '.status // empty' "${THEHIVE_STATE}")"
if [[ "${thehive_status}" != "deployed" ]]; then
  log "TheHive status=${thehive_status}, skipping webhook wiring"
  exit 0
fi

log "TheHive present but webhook wiring is implemented in Plan 2"
exit 0
