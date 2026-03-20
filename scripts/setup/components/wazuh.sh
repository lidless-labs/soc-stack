#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# S³ Stack - Wazuh 4.x Installer
# Installs Wazuh Manager, Indexer, and Dashboard (single-node)
#
# MIT License - Copyright (c) 2024 Solomon Neas
# ------------------------------------------------------------------------------

set -euo pipefail

COMPONENT="Wazuh"
LOG_TAG="[S³:${COMPONENT}]"

# ── Colors ────────────────────────────────────────────────────────────────────
GN="\033[1;92m" RD="\033[01;31m" YW="\033[33m" CY="\033[36m" CL="\033[m"
CM="${GN}✓${CL}" CROSS="${RD}✗${CL}" INFO="${CY}ℹ${CL}"

msg_info() { echo -e " ${INFO} ${LOG_TAG} ${1}..."; }
msg_ok()   { echo -e " ${CM} ${LOG_TAG} ${1}"; }
msg_error(){ echo -e " ${CROSS} ${LOG_TAG} ${1}"; }

# ── Idempotency Check ────────────────────────────────────────────────────────
if systemctl is-active --quiet wazuh-manager 2>/dev/null; then
  msg_ok "Wazuh Manager already running (skipping install)"
  exit 0
fi

# ── System Prep ───────────────────────────────────────────────────────────────
msg_info "Updating system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq &>/dev/null
apt-get upgrade -y -qq &>/dev/null
msg_ok "System updated"

msg_info "Installing prerequisites"
apt-get install -y -qq curl apt-transport-https unzip wget libcap2-bin \
  software-properties-common gnupg lsb-release &>/dev/null
msg_ok "Prerequisites installed"

# ── Wazuh Installation (all-in-one) ──────────────────────────────────────────
msg_info "Downloading Wazuh installation assistant"
curl -sO https://packages.wazuh.com/4.9/wazuh-install.sh
curl -sO https://packages.wazuh.com/4.9/config.yml

# Generate config for single-node
cat > config.yml <<'EOF'
nodes:
  indexer:
    - name: node-1
      ip: "127.0.0.1"
  server:
    - name: wazuh-1
      ip: "127.0.0.1"
  dashboard:
    - name: dashboard
      ip: "127.0.0.1"
EOF

msg_ok "Downloaded Wazuh installer"

msg_info "Running Wazuh installation (this may take several minutes)"
bash wazuh-install.sh --generate-config-files &>/dev/null || true
bash wazuh-install.sh --wazuh-indexer node-1 &>/dev/null
bash wazuh-install.sh --start-cluster &>/dev/null
bash wazuh-install.sh --wazuh-server wazuh-1 &>/dev/null
bash wazuh-install.sh --wazuh-dashboard dashboard &>/dev/null
msg_ok "Wazuh installed successfully"

# ── Verify Services ──────────────────────────────────────────────────────────
msg_info "Verifying services"
for svc in wazuh-manager wazuh-indexer wazuh-dashboard; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    msg_ok "${svc} is running"
  else
    msg_error "${svc} failed to start"
  fi
done

# ── Output ────────────────────────────────────────────────────────────────────
echo ""
msg_ok "Wazuh installation complete"
echo -e "  ${CY}Dashboard:${CL} https://$(hostname -I | awk '{print $1}'):443"
echo -e "  ${CY}API:${CL}       https://$(hostname -I | awk '{print $1}'):55000"
echo -e "  ${CY}Creds:${CL}     admin / admin (change immediately)"
echo ""

# Cleanup
rm -f wazuh-install.sh config.yml
