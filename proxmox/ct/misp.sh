#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# SOC Stack - MISP LXC Installer for Proxmox VE
#
# One-liner:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/solomonneas/soc-stack/main/proxmox/ct/misp.sh)"
#
# Creates an Ubuntu 24.04 LXC, installs Docker + Compose, deploys MISP
# with MariaDB (INNODB_BUFFER_POOL_SIZE tuned for container RAM).
#
# MIT License - Copyright (c) 2026 Solomon Neas
# Source: https://github.com/solomonneas/soc-stack
# ------------------------------------------------------------------------------

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/solomonneas/soc-stack/main"

SOC_STACK_FUNC="$(mktemp)"
trap 'rm -f "$SOC_STACK_FUNC"' EXIT

if command -v wget >/dev/null 2>&1; then
    wget -qO "$SOC_STACK_FUNC" "${REPO_RAW}/proxmox/misc/soc-stack.func"
elif command -v curl >/dev/null 2>&1; then
    curl -fsSL "${REPO_RAW}/proxmox/misc/soc-stack.func" -o "$SOC_STACK_FUNC"
else
    echo "Error: wget or curl is required to download the SOC Stack helper." >&2
    exit 1
fi

if [[ ! -s "$SOC_STACK_FUNC" ]]; then
    echo "Error: failed to download the SOC Stack helper from ${REPO_RAW}." >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$SOC_STACK_FUNC"

APP="MISP"
APP_SLUG="misp"
DEFAULT_CORES=2
DEFAULT_RAM=4096
DEFAULT_DISK=30
PORTS="443 (HTTPS), 80 (HTTP)"

# ── Pre-flight ────────────────────────────────────────────────────────────────
check_root
check_proxmox
check_deps

# ── User prompts ──────────────────────────────────────────────────────────────
show_header "$APP" "Open-source threat intelligence platform for sharing, storing, and correlating IOCs."
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
push_and_run "$CTID" "${REPO_RAW}/proxmox/install/misp-install.sh"

show_completion "$APP" "$CTID" "$CT_PASSWORD" "$PORTS"

echo -e "  ${CY}Default credentials:${CL}"
echo -e "    MISP: admin@misp.local / admin (change on first login)"
echo ""
echo -e "  ${CY}API keys and final credentials:${CL}"
echo -e "    pct exec ${CTID} -- cat /opt/soc-stack/misp/api-keys.txt"
echo ""
