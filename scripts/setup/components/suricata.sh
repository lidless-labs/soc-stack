#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# S³ Stack - Suricata Installer
# Installs Suricata IDS/IPS from official PPA
#
# MIT License - Copyright (c) 2024 Solomon Neas
# ------------------------------------------------------------------------------

set -euo pipefail

COMPONENT="Suricata"
LOG_TAG="[S³:${COMPONENT}]"

GN="\033[1;92m" RD="\033[01;31m" CY="\033[36m" CL="\033[m"
CM="${GN}✓${CL}" CROSS="${RD}✗${CL}" INFO="${CY}ℹ${CL}"

msg_info() { echo -e " ${INFO} ${LOG_TAG} ${1}..."; }
msg_ok()   { echo -e " ${CM} ${LOG_TAG} ${1}"; }
msg_error(){ echo -e " ${CROSS} ${LOG_TAG} ${1}"; }

# ── Idempotency ──────────────────────────────────────────────────────────────
if command -v suricata &>/dev/null; then
  msg_ok "Suricata already installed ($(suricata --build-info | grep 'Suricata version' | head -1 || echo 'installed'))"
  exit 0
fi

# ── System Prep ───────────────────────────────────────────────────────────────
msg_info "Updating system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq &>/dev/null
apt-get upgrade -y -qq &>/dev/null
apt-get install -y -qq curl wget gnupg software-properties-common &>/dev/null
msg_ok "System updated"

# ── Suricata Installation ────────────────────────────────────────────────────
msg_info "Adding Suricata PPA"
add-apt-repository -y ppa:oisf/suricata-stable &>/dev/null
apt-get update -qq &>/dev/null
msg_ok "PPA added"

msg_info "Installing Suricata"
apt-get install -y -qq suricata suricata-update &>/dev/null
msg_ok "Suricata installed"

# ── Configure ─────────────────────────────────────────────────────────────────
msg_info "Configuring Suricata"

IFACE=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
IFACE="${IFACE:-eth0}"

# Update interface in config
if [[ -f /etc/suricata/suricata.yaml ]]; then
  sed -i "s/- interface: eth0/- interface: ${IFACE}/" /etc/suricata/suricata.yaml
fi

msg_ok "Suricata configured on interface ${IFACE}"

# ── Update Rules ──────────────────────────────────────────────────────────────
msg_info "Updating Suricata rules"
suricata-update &>/dev/null || true
msg_ok "Rules updated"

# ── Enable and Start ─────────────────────────────────────────────────────────
msg_info "Starting Suricata"
systemctl enable --now suricata &>/dev/null || true
msg_ok "Suricata started"

# ── Verify ────────────────────────────────────────────────────────────────────
if systemctl is-active --quiet suricata 2>/dev/null; then
  msg_ok "Suricata is running"
else
  msg_error "Suricata failed to start (check journalctl -u suricata)"
fi

echo ""
msg_ok "Suricata installation complete"
echo -e "  ${CY}Logs:${CL}      /var/log/suricata/"
echo -e "  ${CY}Rules:${CL}     /var/lib/suricata/rules/"
echo -e "  ${CY}Config:${CL}    /etc/suricata/suricata.yaml"
echo -e "  ${CY}Interface:${CL} ${IFACE}"
echo ""
