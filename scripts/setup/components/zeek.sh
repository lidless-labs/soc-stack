#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# S³ Stack - Zeek Installer
# Installs Zeek network monitor from official packages
#
# MIT License - Copyright (c) 2024 Solomon Neas
# ------------------------------------------------------------------------------

set -euo pipefail

COMPONENT="Zeek"
LOG_TAG="[S³:${COMPONENT}]"

GN="\033[1;92m" RD="\033[01;31m" CY="\033[36m" CL="\033[m"
CM="${GN}✓${CL}" CROSS="${RD}✗${CL}" INFO="${CY}ℹ${CL}"

msg_info() { echo -e " ${INFO} ${LOG_TAG} ${1}..."; }
msg_ok()   { echo -e " ${CM} ${LOG_TAG} ${1}"; }
msg_error(){ echo -e " ${CROSS} ${LOG_TAG} ${1}"; }

# ── Idempotency ──────────────────────────────────────────────────────────────
if command -v zeek &>/dev/null; then
  msg_ok "Zeek already installed ($(zeek --version 2>/dev/null || echo 'unknown'))"
  exit 0
fi

# ── System Prep ───────────────────────────────────────────────────────────────
msg_info "Updating system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq &>/dev/null
apt-get upgrade -y -qq &>/dev/null
apt-get install -y -qq curl wget gnupg software-properties-common &>/dev/null
msg_ok "System updated"

# ── Zeek Installation ────────────────────────────────────────────────────────
msg_info "Adding Zeek repository"
echo "deb http://download.opensuse.org/repositories/security:/zeek/xUbuntu_22.04/ /" \
  > /etc/apt/sources.list.d/zeek.list
curl -fsSL https://download.opensuse.org/repositories/security:zeek/xUbuntu_22.04/Release.key | \
  gpg --dearmor -o /usr/share/keyrings/zeek.gpg 2>/dev/null
# Fix: add signed-by
echo "deb [signed-by=/usr/share/keyrings/zeek.gpg] http://download.opensuse.org/repositories/security:/zeek/xUbuntu_22.04/ /" \
  > /etc/apt/sources.list.d/zeek.list

apt-get update -qq &>/dev/null
msg_ok "Zeek repository added"

msg_info "Installing Zeek"
apt-get install -y -qq zeek &>/dev/null
msg_ok "Zeek installed"

# ── Configure ─────────────────────────────────────────────────────────────────
msg_info "Configuring Zeek"

# Add to PATH
echo 'export PATH="/opt/zeek/bin:$PATH"' >> /etc/profile.d/zeek.sh
export PATH="/opt/zeek/bin:$PATH"

# Detect primary interface
IFACE=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
IFACE="${IFACE:-eth0}"

# Configure node.cfg
if [[ -f /opt/zeek/etc/node.cfg ]]; then
  cat > /opt/zeek/etc/node.cfg <<EOF
[zeek]
type=standalone
host=localhost
interface=${IFACE}
EOF
fi

# Deploy
if command -v zeekctl &>/dev/null; then
  zeekctl deploy &>/dev/null || true
fi

msg_ok "Zeek configured on interface ${IFACE}"

# ── Verify ────────────────────────────────────────────────────────────────────
if command -v zeek &>/dev/null; then
  msg_ok "Zeek $(zeek --version 2>/dev/null | head -1) installed"
else
  msg_error "Zeek binary not found in PATH"
fi

echo ""
msg_ok "Zeek installation complete"
echo -e "  ${CY}Logs:${CL}      /opt/zeek/logs/current/"
echo -e "  ${CY}Config:${CL}    /opt/zeek/etc/"
echo -e "  ${CY}Interface:${CL} ${IFACE}"
echo ""
