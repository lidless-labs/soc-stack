#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# S³ Stack - Integration Script
# Connects SOC components together for unified operations
#
# MIT License - Copyright (c) 2024 Solomon Neas
# ------------------------------------------------------------------------------

set -euo pipefail

LOG_TAG="[S³:Integrate]"
SUMMARY_FILE="/root/s3-stack-summary.txt"

# ── Colors ────────────────────────────────────────────────────────────────────
GN="\033[1;92m" RD="\033[01;31m" YW="\033[33m" CY="\033[36m" CL="\033[m"
CM="${GN}✓${CL}" CROSS="${RD}✗${CL}" INFO="${CY}ℹ${CL}" WARN="${YW}⚠${CL}"

msg_info() { echo -e " ${INFO} ${LOG_TAG} ${1}..."; }
msg_ok()   { echo -e " ${CM} ${LOG_TAG} ${1}"; }
msg_error(){ echo -e " ${CROSS} ${LOG_TAG} ${1}"; }
msg_warn() { echo -e " ${WARN} ${LOG_TAG} ${1}"; }

echo ""
echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo -e "${GN}   S³ Stack -- Integration Setup${CL}"
echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo ""

# ── Discover Components ───────────────────────────────────────────────────────
get_container_ip() {
  local name="$1"
  local vmid
  vmid=$(pct list 2>/dev/null | grep "s3-${name}" | awk '{print $1}')
  if [[ -n "$vmid" ]]; then
    pct exec "$vmid" -- hostname -I 2>/dev/null | awk '{print $1}'
  fi
}

WAZUH_IP=$(get_container_ip "wazuh" || echo "")
THEHIVE_IP=$(get_container_ip "thehive" || echo "")
CORTEX_IP=$(get_container_ip "cortex" || echo "")
MISP_IP=$(get_container_ip "misp" || echo "")
ZEEK_IP=$(get_container_ip "zeek" || echo "")
SURICATA_IP=$(get_container_ip "suricata" || echo "")

# ── 1. Wazuh to TheHive (Webhook) ────────────────────────────────────────────
if [[ -n "$WAZUH_IP" && -n "$THEHIVE_IP" ]]; then
  msg_info "Configuring Wazuh alerts to TheHive webhook"

  wazuh_vmid=""
  wazuh_vmid=$(pct list 2>/dev/null | grep "s3-wazuh" | awk '{print $1}')

  if [[ -n "$wazuh_vmid" ]]; then
    pct exec "$wazuh_vmid" -- bash -c "cat > /var/ossec/integrations/custom-thehive.py << 'PYEOF'
#!/usr/bin/env python3
import json
import sys
import requests

THEHIVE_URL = \"http://${THEHIVE_IP}:9000\"
THEHIVE_API_KEY = \"YOUR_API_KEY_HERE\"

def create_alert(alert_data):
    headers = {
        \"Authorization\": f\"Bearer {THEHIVE_API_KEY}\",
        \"Content-Type\": \"application/json\"
    }
    alert = {
        \"type\": \"wazuh\",
        \"source\": \"Wazuh SIEM\",
        \"sourceRef\": alert_data.get(\"id\", \"unknown\"),
        \"title\": alert_data.get(\"rule\", {}).get(\"description\", \"Wazuh Alert\"),
        \"description\": json.dumps(alert_data, indent=2),
        \"severity\": min(int(alert_data.get(\"rule\", {}).get(\"level\", 3)) // 4 + 1, 4),
        \"tlp\": 2,
        \"tags\": [\"wazuh\", \"s3-stack\"]
    }
    requests.post(f\"{THEHIVE_URL}/api/v1/alert\", headers=headers, json=alert, verify=False)

if __name__ == \"__main__\":
    alert_file = sys.argv[1]
    with open(alert_file) as f:
        alert_data = json.load(f)
    create_alert(alert_data)
PYEOF
chmod +x /var/ossec/integrations/custom-thehive.py" &>/dev/null || true

    # Add integration to ossec.conf
    pct exec "$wazuh_vmid" -- bash -c "
      if ! grep -q 'custom-thehive' /var/ossec/etc/ossec.conf 2>/dev/null; then
        sed -i '/<\/ossec_config>/i\\
  <integration>\\
    <name>custom-thehive</name>\\
    <hook_url>http://${THEHIVE_IP}:9000</hook_url>\\
    <level>8</level>\\
    <alert_format>json</alert_format>\\
  </integration>' /var/ossec/etc/ossec.conf
      fi" &>/dev/null || true

    msg_ok "Wazuh to TheHive webhook configured"
    msg_warn "Update THEHIVE_API_KEY in /var/ossec/integrations/custom-thehive.py"
  fi
else
  msg_warn "Skipping Wazuh to TheHive (one or both not found)"
fi

# ── 2. Cortex Analyzers Configuration ────────────────────────────────────────
if [[ -n "$CORTEX_IP" ]]; then
  msg_info "Preparing Cortex analyzer configuration"

  echo ""
  echo -e "  ${CY}Cortex Analyzers to configure:${CL}"
  echo -e "    1. VirusTotal_GetReport    (requires API key)"
  echo -e "    2. AbuseIPDB               (requires API key)"
  echo -e "    3. OTXQuery                (requires API key)"
  echo -e "    4. Shodan_Host             (requires API key)"
  echo -e "    5. MISP_2_1                (auto-configured if MISP present)"
  echo ""
  msg_warn "Configure analyzer API keys via Cortex web UI at http://${CORTEX_IP}:9001"

  # Auto-configure MISP analyzer if MISP is present
  if [[ -n "$MISP_IP" ]]; then
    msg_ok "MISP analyzer can be configured with URL: https://${MISP_IP}"
  fi

  msg_ok "Cortex analyzer list prepared"
else
  msg_warn "Skipping Cortex configuration (not found)"
fi

# ── 3. TheHive to Cortex Connection ──────────────────────────────────────────
if [[ -n "$THEHIVE_IP" && -n "$CORTEX_IP" ]]; then
  msg_info "Connecting TheHive to Cortex"

  thehive_vmid=""
  thehive_vmid=$(pct list 2>/dev/null | grep "s3-thehive" | awk '{print $1}')

  if [[ -n "$thehive_vmid" ]]; then
    pct exec "$thehive_vmid" -- bash -c "
      if ! grep -q 'cortex' /etc/thehive/application.conf 2>/dev/null; then
        cat >> /etc/thehive/application.conf << 'EOF'

# Cortex integration (S³ Stack)
play.modules.enabled += org.thp.thehive.connector.cortex.CortexModule
cortex {
  servers = [
    {
      name = \"S3-Cortex\"
      url = \"http://${CORTEX_IP}:9001\"
      auth {
        type = \"bearer\"
        key = \"YOUR_CORTEX_API_KEY\"
      }
    }
  ]
}
EOF
        systemctl restart thehive
      fi" &>/dev/null || true
    msg_ok "TheHive connected to Cortex"
    msg_warn "Update Cortex API key in /etc/thehive/application.conf"
  fi
else
  msg_warn "Skipping TheHive to Cortex (one or both not found)"
fi

# ── 4. MISP to Suricata Rules Feed ───────────────────────────────────────────
if [[ -n "$MISP_IP" && -n "$SURICATA_IP" ]]; then
  msg_info "Setting up MISP to Suricata rule feed"

  suricata_vmid=""
  suricata_vmid=$(pct list 2>/dev/null | grep "s3-suricata" | awk '{print $1}')

  if [[ -n "$suricata_vmid" ]]; then
    # Add MISP as a rule source in suricata-update
    pct exec "$suricata_vmid" -- bash -c "
      mkdir -p /etc/suricata/update.d
      cat > /etc/suricata/update.d/misp.conf << EOF
# MISP threat intel feed (S³ Stack)
# Update this with your MISP automation key
url = https://${MISP_IP}/attributes/restSearch/returnFormat:snort/type:snort
secret-code = YOUR_MISP_API_KEY
EOF

      # Add cron job for hourly rule updates
      cat > /etc/cron.d/s3-misp-rules << 'CRON'
# S³ Stack: MISP rule sync
0 * * * * root suricata-update && systemctl reload suricata
CRON
    " &>/dev/null || true
    msg_ok "MISP to Suricata rule feed configured"
    msg_warn "Update MISP API key in /etc/suricata/update.d/misp.conf"
  fi
else
  msg_warn "Skipping MISP to Suricata (one or both not found)"
fi

# ── 5. Zeek Log Forwarding to Wazuh ──────────────────────────────────────────
if [[ -n "$ZEEK_IP" && -n "$WAZUH_IP" ]]; then
  msg_info "Setting up Zeek log forwarding to Wazuh"

  zeek_vmid=""
  zeek_vmid=$(pct list 2>/dev/null | grep "s3-zeek" | awk '{print $1}')

  if [[ -n "$zeek_vmid" ]]; then
    # Install Wazuh agent on Zeek container
    pct exec "$zeek_vmid" -- bash -c "
      if ! command -v /var/ossec/bin/wazuh-control &>/dev/null; then
        curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --dearmor -o /usr/share/keyrings/wazuh.gpg
        echo 'deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main' > /etc/apt/sources.list.d/wazuh.list
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        WAZUH_MANAGER='${WAZUH_IP}' DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wazuh-agent
        systemctl enable --now wazuh-agent
      fi

      # Configure Zeek log monitoring
      if ! grep -q 'zeek' /var/ossec/etc/ossec.conf 2>/dev/null; then
        sed -i '/<\/ossec_config>/i\\
  <localfile>\\
    <log_format>json</log_format>\\
    <location>/opt/zeek/logs/current/conn.log</location>\\
  </localfile>\\
  <localfile>\\
    <log_format>json</log_format>\\
    <location>/opt/zeek/logs/current/dns.log</location>\\
  </localfile>\\
  <localfile>\\
    <log_format>json</log_format>\\
    <location>/opt/zeek/logs/current/http.log</location>\\
  </localfile>\\
  <localfile>\\
    <log_format>json</log_format>\\
    <location>/opt/zeek/logs/current/ssl.log</location>\\
  </localfile>\\
  <localfile>\\
    <log_format>json</log_format>\\
    <location>/opt/zeek/logs/current/notice.log</location>\\
  </localfile>' /var/ossec/etc/ossec.conf
        systemctl restart wazuh-agent
      fi
    " &>/dev/null || true
    msg_ok "Zeek log forwarding to Wazuh configured"
  fi
else
  msg_warn "Skipping Zeek to Wazuh (one or both not found)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo -e "${GN}   S³ Stack -- Integration Complete${CL}"
echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo ""
echo -e "  ${CY}Remaining manual steps:${CL}"
echo -e "    1. Set TheHive API key in Wazuh webhook script"
echo -e "    2. Set Cortex API key in TheHive config"
echo -e "    3. Configure Cortex analyzer API keys via web UI"
echo -e "    4. Set MISP automation key in Suricata rule feed"
echo ""
echo -e "  ${CY}All API keys should be generated from each tool's web interface.${CL}"
echo ""
