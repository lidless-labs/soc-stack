#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# S³ Stack - Cortex 3.x Installer
# Installs Cortex 3.x with common analyzers
#
# MIT License - Copyright (c) 2024 Solomon Neas
# ------------------------------------------------------------------------------

set -euo pipefail

COMPONENT="Cortex"
LOG_TAG="[S³:${COMPONENT}]"

GN="\033[1;92m" RD="\033[01;31m" CY="\033[36m" CL="\033[m"
CM="${GN}✓${CL}" CROSS="${RD}✗${CL}" INFO="${CY}ℹ${CL}"

msg_info() { echo -e " ${INFO} ${LOG_TAG} ${1}..."; }
msg_ok()   { echo -e " ${CM} ${LOG_TAG} ${1}"; }
msg_error(){ echo -e " ${CROSS} ${LOG_TAG} ${1}"; }

# ── Idempotency ──────────────────────────────────────────────────────────────
if systemctl is-active --quiet cortex 2>/dev/null; then
  msg_ok "Cortex already running (skipping install)"
  exit 0
fi

# ── System Prep ───────────────────────────────────────────────────────────────
msg_info "Updating system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq &>/dev/null
apt-get upgrade -y -qq &>/dev/null
apt-get install -y -qq curl wget gnupg apt-transport-https ca-certificates \
  software-properties-common python3 python3-pip &>/dev/null
msg_ok "System updated"

# ── Java 11 ───────────────────────────────────────────────────────────────────
msg_info "Installing Java 11"
apt-get install -y -qq openjdk-11-jre-headless &>/dev/null
msg_ok "Java 11 installed"

# ── Elasticsearch 7.x ────────────────────────────────────────────────────────
if ! systemctl is-active --quiet elasticsearch 2>/dev/null; then
  msg_info "Installing Elasticsearch 7.x"
  wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | \
    gpg --dearmor -o /usr/share/keyrings/elasticsearch.gpg 2>/dev/null
  echo "deb [signed-by=/usr/share/keyrings/elasticsearch.gpg] https://artifacts.elastic.co/packages/7.x/apt stable main" \
    > /etc/apt/sources.list.d/elasticsearch.list
  apt-get update -qq &>/dev/null
  apt-get install -y -qq elasticsearch &>/dev/null

  cat >> /etc/elasticsearch/elasticsearch.yml <<'EOF'
cluster.name: cortex
node.name: node-1
network.host: 127.0.0.1
http.port: 9200
discovery.type: single-node
xpack.security.enabled: false
EOF

  systemctl enable --now elasticsearch &>/dev/null
  msg_ok "Elasticsearch installed"
else
  msg_ok "Elasticsearch already running"
fi

# ── Cortex 3.x ───────────────────────────────────────────────────────────────
msg_info "Installing Cortex 3.x"
curl -fsSL https://archives.strangebee.com/keys/strangebee.gpg | \
  gpg --dearmor -o /usr/share/keyrings/strangebee.gpg 2>/dev/null
echo "deb [signed-by=/usr/share/keyrings/strangebee.gpg] https://deb.strangebee.com cortex-3.x main" \
  > /etc/apt/sources.list.d/cortex.list
apt-get update -qq &>/dev/null
apt-get install -y -qq cortex &>/dev/null

# Configure Cortex
mkdir -p /opt/cortex/analyzers /opt/cortex/responders
cat > /etc/cortex/application.conf <<'EOF'
search {
  uri = "http://127.0.0.1:9200"
  index = cortex
}

analyzer {
  urls = ["/opt/cortex/analyzers"]
}

responder {
  urls = ["/opt/cortex/responders"]
}
EOF

systemctl enable --now cortex &>/dev/null
msg_ok "Cortex 3.x installed"

# ── Install Analyzers ────────────────────────────────────────────────────────
msg_info "Downloading Cortex analyzers"
if command -v git &>/dev/null || apt-get install -y -qq git &>/dev/null; then
  git clone https://github.com/TheHive-Project/Cortex-Analyzers.git \
    /opt/cortex/Cortex-Analyzers &>/dev/null 2>&1 || true
  ln -sf /opt/cortex/Cortex-Analyzers/analyzers/* /opt/cortex/analyzers/ 2>/dev/null || true
  ln -sf /opt/cortex/Cortex-Analyzers/responders/* /opt/cortex/responders/ 2>/dev/null || true
fi

# Install Python dependencies for common analyzers
pip3 install cortexutils requests &>/dev/null 2>&1 || true
msg_ok "Analyzers configured"

# ── Verify ────────────────────────────────────────────────────────────────────
sleep 5
if systemctl is-active --quiet cortex; then
  msg_ok "Cortex is running"
else
  msg_error "Cortex failed to start (check journalctl -u cortex)"
fi

echo ""
msg_ok "Cortex installation complete"
echo -e "  ${CY}URL:${CL}   http://$(hostname -I | awk '{print $1}'):9001"
echo -e "  ${CY}Setup:${CL} Complete first-run wizard in browser"
echo ""
