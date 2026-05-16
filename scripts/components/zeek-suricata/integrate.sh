#!/usr/bin/env bash
# scripts/components/zeek-suricata/integrate.sh
# Runs on Proxmox HOST. Wires: Suricata <- MISP rule feed, Zeek -> Wazuh agent.

set -euo pipefail

: "${SOC_STATE_DIR:?SOC_STATE_DIR must be set}"

log() { printf '[zs-integrate] %s\n' "$*"; }

ZS_STATE="${SOC_STATE_DIR}/state/zeek-suricata.json"
[[ -f "${ZS_STATE}" ]] || { log "zeek-suricata state missing, skipping"; exit 0; }
[[ "$(jq -r '.status' "${ZS_STATE}")" == "deployed" ]] || { log "not deployed, skipping"; exit 0; }

vmid="$(jq -r '.lxc.vmid // empty' "${ZS_STATE}")"
[[ -n "${vmid}" ]] || { log "no VMID, skipping"; exit 0; }

# --- Suricata <- MISP rule feed ---
MISP_STATE="${SOC_STATE_DIR}/state/misp.json"
if [[ -f "${MISP_STATE}" ]] && [[ "$(jq -r '.status' "${MISP_STATE}")" == "deployed" ]]; then
  misp_url="$(jq -r '.url' "${MISP_STATE}")"
  misp_key="$(jq -r '.api_key' "${MISP_STATE}")"

  if ! pct exec "${vmid}" -- test -f /etc/suricata/update.d/misp.conf 2>/dev/null; then
    log "wiring Suricata -> MISP rule feed"

    tmp="$(mktemp)"
    cat > "${tmp}" <<EOF
# S3 Stack: MISP threat intel rule feed
url = ${misp_url}/attributes/restSearch/returnFormat:snort/type:snort
secret-code = ${misp_key}
EOF
    pct exec "${vmid}" -- mkdir -p /etc/suricata/update.d
    pct push "${vmid}" "${tmp}" /etc/suricata/update.d/misp.conf
    rm -f "${tmp}"

    pct exec "${vmid}" -- bash -c 'cat > /etc/cron.d/s3-misp-rules <<'"'"'CRON'"'"'
# S3 Stack: hourly MISP rule sync
0 * * * * root suricata-update && systemctl reload suricata
CRON'

    log "Suricata MISP feed configured"
  else
    log "Suricata MISP feed already configured, skipping"
  fi
fi

# --- Zeek -> Wazuh agent forward ---
WAZUH_STATE="${SOC_STATE_DIR}/state/wazuh.json"
if [[ -f "${WAZUH_STATE}" ]] && [[ "$(jq -r '.status' "${WAZUH_STATE}")" == "deployed" ]]; then
  wazuh_ep="$(jq -r '.agent_endpoint // empty' "${WAZUH_STATE}")"
  wazuh_mgr="${wazuh_ep%:*}"
  [[ -n "${wazuh_mgr}" ]] || { log "wazuh has no agent_endpoint, skipping zeek->wazuh"; exit 0; }

  if ! pct exec "${vmid}" -- test -f /var/ossec/bin/wazuh-control 2>/dev/null; then
    log "installing Wazuh agent in zeek-suricata LXC"
    pct exec "${vmid}" -- bash -c "
      curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --dearmor -o /usr/share/keyrings/wazuh.gpg
      echo 'deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main' > /etc/apt/sources.list.d/wazuh.list
      apt-get update -qq
      WAZUH_MANAGER='${wazuh_mgr}' DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wazuh-agent
      systemctl enable --now wazuh-agent
    "
    log "Wazuh agent installed"
  fi

  if ! pct exec "${vmid}" -- grep -q '/opt/zeek/logs/current/conn.log' /var/ossec/etc/ossec.conf 2>/dev/null; then
    log "wiring Zeek logs into Wazuh agent ossec.conf"
    # shellcheck disable=SC2016
    pct exec "${vmid}" -- bash -c 'sed -i '\''/<\/ossec_config>/i\
  <localfile>\
    <log_format>json</log_format>\
    <location>/opt/zeek/logs/current/conn.log</location>\
  </localfile>\
  <localfile>\
    <log_format>json</log_format>\
    <location>/opt/zeek/logs/current/dns.log</location>\
  </localfile>\
  <localfile>\
    <log_format>json</log_format>\
    <location>/opt/zeek/logs/current/http.log</location>\
  </localfile>\
  <localfile>\
    <log_format>json</log_format>\
    <location>/opt/zeek/logs/current/ssl.log</location>\
  </localfile>\
  <localfile>\
    <log_format>json</log_format>\
    <location>/opt/zeek/logs/current/notice.log</location>\
  </localfile>'\'' /var/ossec/etc/ossec.conf'
    pct exec "${vmid}" -- systemctl restart wazuh-agent
    log "Zeek log forwarding configured"
  fi
fi

log "zeek-suricata integration phase complete"
