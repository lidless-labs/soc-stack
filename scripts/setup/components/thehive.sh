#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# S³ Stack - TheHive 5.x Installer
# Installs TheHive 5.x with Elasticsearch 7.x and Cassandra
#
# MIT License - Copyright (c) 2024 Solomon Neas
# ------------------------------------------------------------------------------

set -euo pipefail

COMPONENT="TheHive"
LOG_TAG="[S³:${COMPONENT}]"

GN="\033[1;92m" RD="\033[01;31m" CY="\033[36m" CL="\033[m"
CM="${GN}✓${CL}" CROSS="${RD}✗${CL}" INFO="${CY}ℹ${CL}"

msg_info() { echo -e " ${INFO} ${LOG_TAG} ${1}..."; }
msg_ok()   { echo -e " ${CM} ${LOG_TAG} ${1}"; }
msg_error(){ echo -e " ${CROSS} ${LOG_TAG} ${1}"; }

# ── Idempotency ──────────────────────────────────────────────────────────────
if systemctl is-active --quiet thehive 2>/dev/null; then
  msg_ok "TheHive already running (skipping install)"
  exit 0
fi

# ── System Prep ───────────────────────────────────────────────────────────────
msg_info "Updating system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq &>/dev/null
apt-get upgrade -y -qq &>/dev/null
apt-get install -y -qq curl wget gnupg apt-transport-https ca-certificates \
  software-properties-common &>/dev/null
msg_ok "System updated"

# ── Java 11 ───────────────────────────────────────────────────────────────────
msg_info "Installing Java 11"
apt-get install -y -qq openjdk-11-jre-headless &>/dev/null
msg_ok "Java 11 installed"

# ── Cassandra ─────────────────────────────────────────────────────────────────
msg_info "Installing Apache Cassandra"
curl -fsSL https://downloads.apache.org/cassandra/KEYS | gpg --dearmor -o /usr/share/keyrings/cassandra.gpg 2>/dev/null
echo "deb [signed-by=/usr/share/keyrings/cassandra.gpg] https://debian.cassandra.apache.org 40x main" \
  > /etc/apt/sources.list.d/cassandra.sources.list
apt-get update -qq &>/dev/null
apt-get install -y -qq cassandra &>/dev/null
systemctl enable --now cassandra &>/dev/null
msg_ok "Cassandra installed and running"

# ── Elasticsearch 7.x ────────────────────────────────────────────────────────
msg_info "Installing Elasticsearch 7.x"
wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | \
  gpg --dearmor -o /usr/share/keyrings/elasticsearch.gpg 2>/dev/null
echo "deb [signed-by=/usr/share/keyrings/elasticsearch.gpg] https://artifacts.elastic.co/packages/7.x/apt stable main" \
  > /etc/apt/sources.list.d/elasticsearch.list
apt-get update -qq &>/dev/null
apt-get install -y -qq elasticsearch &>/dev/null

# Configure for TheHive
cat >> /etc/elasticsearch/elasticsearch.yml <<'EOF'
cluster.name: thehive
node.name: node-1
network.host: 127.0.0.1
http.port: 9200
discovery.type: single-node
xpack.security.enabled: false
EOF

systemctl enable --now elasticsearch &>/dev/null
msg_ok "Elasticsearch 7.x installed"

# ── TheHive 5.x ──────────────────────────────────────────────────────────────
msg_info "Installing TheHive 5.x"
curl -fsSL https://archives.strangebee.com/keys/strangebee.gpg | \
  gpg --dearmor -o /usr/share/keyrings/strangebee.gpg 2>/dev/null
echo "deb [signed-by=/usr/share/keyrings/strangebee.gpg] https://deb.strangebee.com thehive-5.x main" \
  > /etc/apt/sources.list.d/strangebee.list
apt-get update -qq &>/dev/null
apt-get install -y -qq thehive &>/dev/null

# Set permissions
chown -R thehive:thehive /opt/thp/thehive
mkdir -p /opt/thp/thehive/index
chown -R thehive:thehive /opt/thp/thehive/index

systemctl enable --now thehive &>/dev/null
msg_ok "TheHive 5.x installed and running"

# ── Verify ────────────────────────────────────────────────────────────────────
sleep 5
if systemctl is-active --quiet thehive; then
  msg_ok "TheHive is running"
else
  msg_error "TheHive failed to start (check journalctl -u thehive)"
fi

echo ""
msg_ok "TheHive installation complete"
echo -e "  ${CY}URL:${CL}   http://$(hostname -I | awk '{print $1}'):9000"
echo -e "  ${CY}Creds:${CL} admin@thehive.local / secret"
echo ""
