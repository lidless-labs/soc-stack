#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# S³ Stack - MISP Installer
# Installs MISP using the official INSTALL.sh script
#
# MIT License - Copyright (c) 2024 Solomon Neas
# ------------------------------------------------------------------------------

set -euo pipefail

COMPONENT="MISP"
LOG_TAG="[S³:${COMPONENT}]"

GN="\033[1;92m" RD="\033[01;31m" CY="\033[36m" CL="\033[m"
CM="${GN}✓${CL}" CROSS="${RD}✗${CL}" INFO="${CY}ℹ${CL}"

msg_info() { echo -e " ${INFO} ${LOG_TAG} ${1}..."; }
msg_ok()   { echo -e " ${CM} ${LOG_TAG} ${1}"; }
msg_error(){ echo -e " ${CROSS} ${LOG_TAG} ${1}"; }

# ── Idempotency ──────────────────────────────────────────────────────────────
if [[ -d "/var/www/MISP" ]] && systemctl is-active --quiet apache2 2>/dev/null; then
  msg_ok "MISP already installed (skipping)"
  exit 0
fi

# ── System Prep ───────────────────────────────────────────────────────────────
msg_info "Updating system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq &>/dev/null
apt-get upgrade -y -qq &>/dev/null
apt-get install -y -qq curl wget git &>/dev/null
msg_ok "System updated"

# ── MISP Install ─────────────────────────────────────────────────────────────
msg_info "Downloading MISP installer (this will take a while)"
wget -qO /tmp/INSTALL.sh https://raw.githubusercontent.com/MISP/MISP/2.4/INSTALL/INSTALL.sh
chmod +x /tmp/INSTALL.sh
msg_ok "MISP installer downloaded"

msg_info "Running MISP installation (this may take 15-30 minutes)"
bash /tmp/INSTALL.sh -A -u &>/dev/null || {
  msg_error "MISP auto-install failed, trying core install"
  bash /tmp/INSTALL.sh -c &>/dev/null || true
}
msg_ok "MISP installation complete"

# ── Verify ────────────────────────────────────────────────────────────────────
if [[ -d "/var/www/MISP" ]]; then
  msg_ok "MISP directory exists"
else
  msg_error "MISP directory not found"
fi

if systemctl is-active --quiet apache2 2>/dev/null; then
  msg_ok "Apache2 is running"
elif systemctl is-active --quiet nginx 2>/dev/null; then
  msg_ok "Nginx is running"
fi

echo ""
msg_ok "MISP installation complete"
echo -e "  ${CY}URL:${CL}   https://$(hostname -I | awk '{print $1}')"
echo -e "  ${CY}Creds:${CL} admin@admin.test / admin"
echo ""

rm -f /tmp/INSTALL.sh
