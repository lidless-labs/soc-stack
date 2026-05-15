#!/usr/bin/env bash
# scripts/components/thehive-cortex/integrate.sh
# Runs on the Proxmox HOST after deploy. Wires TheHive <-> Cortex API connection.

set -euo pipefail

: "${SOC_STATE_DIR:?SOC_STATE_DIR must be set}"

log() { printf '[thc-integrate] %s\n' "$*"; }

STATE="${SOC_STATE_DIR}/state/thehive-cortex.json"
[[ -f "${STATE}" ]] || { log "thehive-cortex state missing, skipping"; exit 0; }

thehive_url="$(jq -r '.thehive.url // empty' "${STATE}")"
thehive_key="$(jq -r '.thehive.api_key // empty' "${STATE}")"
cortex_url="$(jq -r '.cortex.url // empty' "${STATE}")"
cortex_key="$(jq -r '.cortex.api_key // empty' "${STATE}")"

if [[ -z "${thehive_url}" || -z "${cortex_url}" || -z "${cortex_key}" ]]; then
  log "missing thehive/cortex coords, cannot wire"
  exit 0
fi

# TheHive -> Cortex connector config (admin API)
# TheHive 5 API: POST /api/config/cortex with the Cortex server entry.
# Idempotent: if a server named "S3-CORTEX" is already configured, skip.
existing="$(curl -sf -H "Authorization: Bearer ${thehive_key}" \
  "${thehive_url}/api/v1/config/cortex" 2>/dev/null \
  | jq -r '.servers[]?.name' 2>/dev/null | grep -x "S3-CORTEX" || true)"

if [[ -n "${existing}" ]]; then
  log "Cortex link already configured in TheHive, skipping"
  exit 0
fi

# same LXC, but TheHive will hit it via internal docker network when run inline.
# Use the external URL since compose exposes it.
cortex_internal_url="${cortex_url}"

payload="$(jq -n \
  --arg name "S3-CORTEX" \
  --arg url "${cortex_internal_url}" \
  --arg key "${cortex_key}" \
  '{servers: [{name: $name, url: $url, auth: {type: "bearer", key: $key}}]}')"

if curl -sf -H "Authorization: Bearer ${thehive_key}" \
  -H "Content-Type: application/json" \
  -X PUT "${thehive_url}/api/v1/config/cortex" \
  -d "${payload}" >/dev/null; then
  log "TheHive -> Cortex link configured"
else
  log "WARN: TheHive -> Cortex link config failed (manual fixup may be required)"
fi

exit 0
