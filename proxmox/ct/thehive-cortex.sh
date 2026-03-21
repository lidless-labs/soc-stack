#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# SOC Stack - TheHive + Cortex LXC Installer for Proxmox VE
#
# One-liner:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/solomonneas/soc-stack/main/proxmox/ct/thehive-cortex.sh)"
#
# Creates an Ubuntu 24.04 LXC, installs Docker + Compose, deploys
# TheHive 5.4 + Cortex 3.1.8, and runs the automated setup script
# (account creation, CSRF handling, API key generation, integration wiring).
#
# MIT License - Copyright (c) 2026 Solomon Neas
# Source: https://github.com/solomonneas/soc-stack
# ------------------------------------------------------------------------------

REPO_RAW="https://raw.githubusercontent.com/solomonneas/soc-stack/main"

source <(wget -qO - "${REPO_RAW}/proxmox/misc/soc-stack.func")

APP="TheHive + Cortex"
APP_SLUG="thehive-cortex"
DEFAULT_CORES=2
DEFAULT_RAM=4096
DEFAULT_DISK=30
PORTS="9000 (TheHive), 9001 (Cortex)"

# ── Pre-flight ────────────────────────────────────────────────────────────────
check_root
check_proxmox
check_deps

# ── User prompts ──────────────────────────────────────────────────────────────
show_header "$APP" "Incident response platform with case management (TheHive) and observable analysis (Cortex)."
select_settings "$APP" $DEFAULT_CORES $DEFAULT_RAM $DEFAULT_DISK
select_storage
select_network

# ── Confirm ───────────────────────────────────────────────────────────────────
if ! whiptail --title "SOC Stack: ${APP}" \
    --yesno "Create container with these settings?\n\n  CPU:     ${CT_CORES} cores\n  RAM:     $((CT_RAM / 1024))GB\n  Disk:    ${CT_DISK}GB\n  Storage: ${CT_STORAGE}\n  Bridge:  ${CT_BRIDGE}\n  Ports:   ${PORTS}" 18 58; then
    echo "Cancelled."
    exit 0
fi

# ── Build ─────────────────────────────────────────────────────────────────────
ensure_template "local"

CTID=$(get_next_vmid)
CT_PASSWORD=$(create_container "$APP_SLUG" "$CTID")

start_and_wait "$CTID"
push_and_run "$CTID" "${REPO_RAW}/proxmox/install/thehive-cortex-install.sh"

show_completion "$APP" "$CTID" "$CT_PASSWORD" "$PORTS"

echo -e "  ${CY}Default credentials:${CL}"
echo -e "    TheHive:  admin@thehive.local / secret (changed by setup)"
echo -e "    Cortex:   admin / (set during setup)"
echo ""
echo -e "  ${CY}API keys and final credentials:${CL}"
echo -e "    pct exec ${CTID} -- cat /opt/soc-stack/thehive-cortex/api-keys.txt"
echo ""
