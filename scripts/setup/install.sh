#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# S³ Stack Installer
# Proxmox VE Community Install Script
#
# MIT License
# Copyright (c) 2024 Solomon Neas
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
# ------------------------------------------------------------------------------

set -euo pipefail

# ── Globals ───────────────────────────────────────────────────────────────────
SCRIPT_VERSION="1.0.0"
REPO_URL="https://raw.githubusercontent.com/solomonneas/soc-stack/main"
LOG_FILE="/var/log/s3-stack-install.log"
TEMP_DIR=""
SELECTED_COMPONENTS=()
COMPONENT_TYPES=()
BRIDGE="vmbr0"
VLAN_TAG=""
IP_MODE="dhcp"
IP_RANGE=""
STORAGE="local-lvm"
PRESET="standard"
INSTALL_MCP="no"
INSTALL_DASHBOARDS="no"
DASHBOARD_DEPLOY="lxc"

# ── Component Definitions ─────────────────────────────────────────────────────
declare -A COMP_NAMES=(
  [wazuh]="Wazuh"
  [thehive]="TheHive"
  [cortex]="Cortex"
  [misp]="MISP"
  [zeek]="Zeek"
  [suricata]="Suricata"
)
declare -A COMP_DESC=(
  [wazuh]="SIEM/XDR Platform"
  [thehive]="Case Management"
  [cortex]="SOAR/Analyzers"
  [misp]="Threat Intel Platform"
  [zeek]="Network Monitor"
  [suricata]="IDS/IPS Engine"
)
declare -A COMP_PORTS=(
  [wazuh]="443,1514,1515,55000"
  [thehive]="9000"
  [cortex]="9001"
  [misp]="443"
  [zeek]="47760"
  [suricata]="N/A"
)

# Resource presets: RAM(MB) DISK(GB) CORES
declare -A PRESET_MINIMAL=(
  [wazuh]="2048 30 1"
  [thehive]="2048 20 1"
  [cortex]="1024 15 1"
  [misp]="2048 20 1"
  [zeek]="1024 15 1"
  [suricata]="1024 15 1"
)
declare -A PRESET_STANDARD=(
  [wazuh]="4096 50 2"
  [thehive]="4096 30 2"
  [cortex]="2048 20 2"
  [misp]="4096 30 2"
  [zeek]="2048 20 2"
  [suricata]="2048 20 2"
)
declare -A PRESET_PRODUCTION=(
  [wazuh]="8192 100 4"
  [thehive]="8192 60 4"
  [cortex]="4096 40 2"
  [misp]="8192 60 4"
  [zeek]="4096 40 4"
  [suricata]="4096 40 4"
)

# ── Colors ────────────────────────────────────────────────────────────────────
RD="\033[01;31m"
GN="\033[1;92m"
YW="\033[33m"
CY="\033[36m"
CL="\033[m"
BFR="\\r\\033[K"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
INFO="${CY}ℹ${CL}"
WARN="${YW}⚠${CL}"

# ── Logging ───────────────────────────────────────────────────────────────────
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/s3-stack-install.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

msg_info() {
  echo -ne " ${INFO} ${1}..."
  log "INFO: $1"
}

msg_ok() {
  echo -e "${BFR} ${CM} ${1}"
  log "OK: $1"
}

msg_error() {
  echo -e "${BFR} ${CROSS} ${1}"
  log "ERROR: $1"
}

msg_warn() {
  echo -e "${BFR} ${WARN} ${1}"
  log "WARN: $1"
}

# ── Cleanup ───────────────────────────────────────────────────────────────────
cleanup() {
  [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR:-}" ]] && rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# ── Pre-flight Checks ────────────────────────────────────────────────────────
check_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    msg_error "This script must be run as root"
    echo -e "  Run: ${CY}sudo bash install.sh${CL}"
    exit 1
  fi
}

check_proxmox() {
  if ! command -v pveversion &>/dev/null; then
    msg_error "Proxmox VE not detected"
    echo -e "  This script must run on a Proxmox VE host (not inside a VM or container)."
    exit 1
  fi

  local pve_ver
  pve_ver="$(pveversion --verbose | head -1 | grep -oP '\d+\.\d+')"
  local pve_major="${pve_ver%%.*}"

  if [[ "$pve_major" -lt 7 ]]; then
    msg_error "Proxmox VE ${pve_ver} is not supported (requires 7.x or 8.x)"
    exit 1
  fi

  msg_ok "Proxmox VE ${pve_ver} detected"
}

check_dependencies() {
  local deps=(whiptail wget curl jq openssl)
  for dep in "${deps[@]}"; do
    if ! command -v "$dep" &>/dev/null; then
      msg_info "Installing ${dep}"
      apt-get update -qq &>/dev/null
      apt-get install -y -qq "$dep" &>/dev/null
      msg_ok "Installed ${dep}"
    fi
  done
}

# ── VMID Helper ───────────────────────────────────────────────────────────────
get_next_vmid() {
  pvesh get /cluster/nextid 2>/dev/null | tr -d '"'
}

# ── Template Download ─────────────────────────────────────────────────────────
ensure_template() {
  local storage="$1"
  local template="ubuntu-22.04-standard_22.04-1_amd64.tar.zst"

  if ! pveam list "$storage" 2>/dev/null | grep -q "ubuntu-22.04"; then
    msg_info "Downloading Ubuntu 22.04 LXC template"
    pveam update &>/dev/null
    pveam download "$storage" "$template" &>/dev/null
    msg_ok "Downloaded Ubuntu 22.04 template"
  else
    msg_ok "Ubuntu 22.04 template already available"
  fi
}

# ── Whiptail Screens ─────────────────────────────────────────────────────────
show_splash() {
  whiptail --title "S³ Stack Installer v${SCRIPT_VERSION}" --msgbox "\
    ____        _                             _        ____ _____
   / ___|  ___ | | ___  _ __ ___   ___  _ __ ( )___   / ___|___ /
   \\___ \\ / _ \\| |/ _ \\| '_ \` _ \\ / _ \\| '_ \\|// __| | \\___ \\ |_ \\
    ___) | (_) | | (_) | | | | | | (_) | | | | \\__ \\  ___) |__) |
   |____/ \\___/|_|\\___/|_| |_| |_|\\___/|_| |_| |___/ |____/____/

              S³ Stack  --  SOC in a Box

   Deploy a full Security Operations Center on Proxmox VE.

   Components: Wazuh, TheHive, Cortex, MISP, Zeek, Suricata

   Version: ${SCRIPT_VERSION}
   License: MIT
   GitHub:  github.com/solomonneas/soc-stack
" 22 74
}

select_components() {
  local choices
  choices=$(whiptail --title "S³ Stack: Select Components" \
    --checklist "Choose which SOC components to deploy:\n(Space to select, Enter to confirm)" 20 74 6 \
    "wazuh"    "Wazuh 4.x       SIEM/XDR Platform" ON \
    "thehive"  "TheHive 5.x     Case Management" ON \
    "cortex"   "Cortex 3.x      SOAR/Analyzers" ON \
    "misp"     "MISP            Threat Intel Platform" ON \
    "zeek"     "Zeek            Network Monitor" OFF \
    "suricata" "Suricata        IDS/IPS Engine" OFF \
    3>&1 1>&2 2>&3) || { msg_error "Component selection cancelled"; exit 1; }

  if [[ -z "$choices" ]]; then
    msg_error "No components selected"
    exit 1
  fi

  SELECTED_COMPONENTS=()
  for comp in $choices; do
    comp="${comp//\"/}"
    SELECTED_COMPONENTS+=("$comp")
  done
}

select_deploy_type() {
  COMPONENT_TYPES=()
  for comp in "${SELECTED_COMPONENTS[@]}"; do
    local name="${COMP_NAMES[$comp]}"
    local dtype
    dtype=$(whiptail --title "S³ Stack: ${name} Deploy Type" \
      --radiolist "How should ${name} be deployed?" 12 64 2 \
      "lxc" "LXC Container (recommended, less resources)" ON \
      "vm"  "Virtual Machine (full isolation)" OFF \
      3>&1 1>&2 2>&3) || { msg_error "Cancelled"; exit 1; }
    COMPONENT_TYPES+=("${dtype//\"/}")
  done
}

select_preset() {
  PRESET=$(whiptail --title "S³ Stack: Resource Preset" \
    --radiolist "Select a resource allocation preset:" 14 68 3 \
    "minimal"    "Lab/Testing    (low resources, single core)" OFF \
    "standard"   "Small SOC      (balanced, recommended)" ON \
    "production" "Production     (high resources, multi-core)" OFF \
    3>&1 1>&2 2>&3) || { msg_error "Cancelled"; exit 1; }
  PRESET="${PRESET//\"/}"
}

select_network() {
  BRIDGE=$(whiptail --title "S³ Stack: Network Bridge" \
    --inputbox "Enter the Proxmox bridge interface:" 10 60 "vmbr0" \
    3>&1 1>&2 2>&3) || { msg_error "Cancelled"; exit 1; }

  VLAN_TAG=$(whiptail --title "S³ Stack: VLAN Tag" \
    --inputbox "Enter VLAN tag (leave empty for none):" 10 60 "" \
    3>&1 1>&2 2>&3) || { msg_error "Cancelled"; exit 1; }

  IP_MODE=$(whiptail --title "S³ Stack: IP Configuration" \
    --radiolist "How should IPs be assigned?" 12 60 2 \
    "dhcp"   "DHCP (automatic)" ON \
    "static" "Static IP range" OFF \
    3>&1 1>&2 2>&3) || { msg_error "Cancelled"; exit 1; }
  IP_MODE="${IP_MODE//\"/}"

  if [[ "$IP_MODE" == "static" ]]; then
    IP_RANGE=$(whiptail --title "S³ Stack: Static IP Range" \
      --inputbox "Enter starting IP (CIDR notation, e.g. 198.51.100.10/24):" 10 64 "198.51.100.10/24" \
      3>&1 1>&2 2>&3) || { msg_error "Cancelled"; exit 1; }
  fi
}

select_storage() {
  local storages
  storages=$(pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | head -10)

  local items=()
  local first="ON"
  while IFS= read -r s; do
    [[ -z "$s" ]] && continue
    items+=("$s" "" "$first")
    first="OFF"
  done <<< "$storages"

  if [[ ${#items[@]} -eq 0 ]]; then
    items=("local-lvm" "" "ON" "local" "" "OFF")
  fi

  STORAGE=$(whiptail --title "S³ Stack: Storage Selection" \
    --radiolist "Select storage for containers/VMs:" 16 60 6 \
    "${items[@]}" \
    3>&1 1>&2 2>&3) || { msg_error "Cancelled"; exit 1; }
  STORAGE="${STORAGE//\"/}"
}

ask_mcp() {
  if whiptail --title "S³ Stack: MCP Servers" \
    --yesno "Install MCP (Model Context Protocol) servers for AI integration?\n\nThis adds MCP connectors for Wazuh, TheHive, MISP, Cortex, Suricata, and Zeek." 12 72; then
    INSTALL_MCP="yes"
  else
    INSTALL_MCP="no"
  fi
}

ask_dashboards() {
  if whiptail --title "S³ Stack: Custom Dashboards" \
    --yesno "Install custom analysis dashboards?\n\nThis deploys two tools built for the S³ Stack:\n\n  - Bro Hunter: Zeek log analysis and threat hunting\n  - Playbook Forge: IR playbook builder with visual flowcharts\n\nBoth are served from a single LXC container with nginx\nreverse proxy (recommended). Minimal resource overhead." 16 74; then
    INSTALL_DASHBOARDS="yes"

    DASHBOARD_DEPLOY=$(whiptail --title "S³ Stack: Dashboard Deploy Type" \
      --radiolist "How should the dashboards be deployed?" 14 74 2 \
      "lxc"    "Shared LXC Container (recommended, ~1GB RAM)" ON \
      "vm"     "Virtual Machine (full isolation, more resources)" OFF \
      3>&1 1>&2 2>&3) || { msg_error "Cancelled"; exit 1; }
    DASHBOARD_DEPLOY="${DASHBOARD_DEPLOY//\"/}"
  else
    INSTALL_DASHBOARDS="no"
  fi
}

show_confirmation() {
  local summary="S³ Stack Installation Summary\n\n"
  summary+="Preset:  ${PRESET}\n"
  summary+="Storage: ${STORAGE}\n"
  summary+="Bridge:  ${BRIDGE}"
  [[ -n "$VLAN_TAG" ]] && summary+=" (VLAN ${VLAN_TAG})"
  summary+="\nIP Mode: ${IP_MODE}"
  [[ "$IP_MODE" == "static" ]] && summary+=" (${IP_RANGE})"
  summary+="\nMCP:     ${INSTALL_MCP}"
  summary+="\nDashboards: ${INSTALL_DASHBOARDS}"
  [[ "$INSTALL_DASHBOARDS" == "yes" ]] && summary+=" (${DASHBOARD_DEPLOY})"
  summary+="\n\n"
  summary+="Components:\n"

  for i in "${!SELECTED_COMPONENTS[@]}"; do
    local comp="${SELECTED_COMPONENTS[$i]}"
    local dtype="${COMPONENT_TYPES[$i]}"
    local name="${COMP_NAMES[$comp]}"

    local res
    case "$PRESET" in
      minimal)    res="${PRESET_MINIMAL[$comp]}" ;;
      production) res="${PRESET_PRODUCTION[$comp]}" ;;
      *)          res="${PRESET_STANDARD[$comp]}" ;;
    esac

    local ram disk cores
    read -r ram disk cores <<< "$res"
    summary+="  ${name} (${dtype^^}) - $((ram/1024))GB RAM, ${disk}GB disk, ${cores} cores\n"
  done

  if ! whiptail --title "S³ Stack: Confirm Installation" \
    --yesno "${summary}\nProceed with installation?" 26 74; then
    msg_error "Installation cancelled by user"
    exit 0
  fi
}

# ── Resource Getter ───────────────────────────────────────────────────────────
get_resources() {
  local comp="$1"
  case "$PRESET" in
    minimal)    echo "${PRESET_MINIMAL[$comp]}" ;;
    production) echo "${PRESET_PRODUCTION[$comp]}" ;;
    *)          echo "${PRESET_STANDARD[$comp]}" ;;
  esac
}

# ── LXC Creation ──────────────────────────────────────────────────────────────
create_lxc() {
  local comp="$1"
  local vmid="$2"

  local ram disk cores
  read -r ram disk cores <<< "$(get_resources "$comp")"

  local hostname="s3-${comp}"

  # Find template
  local template
  template=$(pveam list local 2>/dev/null | grep "ubuntu-22.04" | awk '{print $1}' | head -1)
  if [[ -z "$template" ]]; then
    template=$(pveam list "$STORAGE" 2>/dev/null | grep "ubuntu-22.04" | awk '{print $1}' | head -1)
  fi
  if [[ -z "$template" ]]; then
    msg_error "No Ubuntu 22.04 template found"
    return 1
  fi

  msg_info "Creating LXC ${hostname} (ID: ${vmid})"

  local net_config="name=eth0,bridge=${BRIDGE}"
  [[ -n "$VLAN_TAG" ]] && net_config+=",tag=${VLAN_TAG}"

  if [[ "$IP_MODE" == "dhcp" ]]; then
    net_config+=",ip=dhcp"
  else
    local base_ip="${IP_RANGE%/*}"
    local cidr="${IP_RANGE#*/}"
    local base_last="${base_ip##*.}"
    local base_prefix="${base_ip%.*}"
    local idx=0
    for c in "${SELECTED_COMPONENTS[@]}"; do
      [[ "$c" == "$comp" ]] && break
      ((idx++))
    done
    local ip="${base_prefix}.$((base_last + idx))/${cidr}"
    local gw="${base_prefix}.1"
    net_config+=",ip=${ip},gw=${gw}"
  fi

  local password
  password="$(openssl rand -base64 16)"

  pct create "$vmid" "$template" \
    --hostname "$hostname" \
    --memory "$ram" \
    --cores "$cores" \
    --rootfs "${STORAGE}:${disk}" \
    --net0 "$net_config" \
    --password "$password" \
    --unprivileged 1 \
    --features nesting=1 \
    --onboot 1 \
    --start 0 \
    &>> "$LOG_FILE"

  msg_ok "Created LXC ${hostname} (ID: ${vmid})"
  echo "$password"
}

# ── VM Creation ───────────────────────────────────────────────────────────────
create_vm() {
  local comp="$1"
  local vmid="$2"
  local hostname="s3-${comp}"

  local ram disk cores
  read -r ram disk cores <<< "$(get_resources "$comp")"

  msg_info "Creating VM ${hostname} (ID: ${vmid})"

  local net_config="virtio,bridge=${BRIDGE}"
  [[ -n "$VLAN_TAG" ]] && net_config+=",tag=${VLAN_TAG}"

  qm create "$vmid" \
    --name "$hostname" \
    --memory "$ram" \
    --cores "$cores" \
    --net0 "$net_config" \
    --scsihw virtio-scsi-single \
    --scsi0 "${STORAGE}:${disk}" \
    --boot order=scsi0 \
    --onboot 1 \
    --start 0 \
    &>> "$LOG_FILE" 2>&1 || true

  msg_ok "Created VM ${hostname} (ID: ${vmid})"
}

# ── Component Installation ────────────────────────────────────────────────────
install_component() {
  local comp="$1"
  local vmid="$2"
  local dtype="$3"
  local name="${COMP_NAMES[$comp]}"

  msg_info "Installing ${name} inside container ${vmid}"

  local script_url="${REPO_URL}/scripts/setup/components/${comp}.sh"
  local script_path="${TEMP_DIR}/${comp}.sh"

  wget -qO "$script_path" "$script_url" 2>/dev/null || true

  if [[ "$dtype" == "lxc" ]]; then
    pct start "$vmid" &>/dev/null || true
    sleep 5

    # Wait for network
    local retries=0
    while ! pct exec "$vmid" -- ping -c1 -W2 8.8.8.8 &>/dev/null; do
      ((retries++))
      [[ $retries -ge 30 ]] && { msg_warn "Network timeout for ${vmid}"; break; }
      sleep 2
    done

    if [[ -f "$script_path" && -s "$script_path" ]]; then
      pct push "$vmid" "$script_path" "/tmp/${comp}.sh" &>/dev/null
      pct exec "$vmid" -- bash "/tmp/${comp}.sh" &>> "$LOG_FILE" || true
    fi
  fi

  msg_ok "Installed ${name} (ID: ${vmid})"
}

# ── Firewall Rules ────────────────────────────────────────────────────────────
setup_firewall() {
  msg_info "Configuring firewall rules between S³ Stack components"

  mkdir -p /etc/pve/firewall

  local fw_conf="/etc/pve/firewall/cluster.fw"
  if [[ ! -f "$fw_conf" ]]; then
    cat > "$fw_conf" <<'EOF'
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT

[RULES]
# S³ Stack: allow inter-component traffic
EOF
  fi

  for vmid_file in "${TEMP_DIR}"/vmid_*; do
    [[ -f "$vmid_file" ]] || continue
    local vmid
    vmid="$(cat "$vmid_file")"
    cat > "/etc/pve/firewall/${vmid}.fw" <<EOF
[OPTIONS]
enable: 1
policy_in: ACCEPT

[RULES]
# S³ Stack: allow all inbound for this component
IN ACCEPT
EOF
  done

  msg_ok "Firewall rules configured"
}

# ── Summary ───────────────────────────────────────────────────────────────────
generate_summary() {
  echo ""
  echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
  echo -e "${GN}   S³ Stack -- Installation Complete!${CL}"
  echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
  echo ""

  for i in "${!SELECTED_COMPONENTS[@]}"; do
    local comp="${SELECTED_COMPONENTS[$i]}"
    local dtype="${COMPONENT_TYPES[$i]}"
    local name="${COMP_NAMES[$comp]}"
    local ports="${COMP_PORTS[$comp]}"

    local vmid="N/A"
    [[ -f "${TEMP_DIR}/vmid_${comp}" ]] && vmid="$(cat "${TEMP_DIR}/vmid_${comp}")"

    local password="N/A"
    [[ -f "${TEMP_DIR}/pass_${comp}" ]] && password="$(cat "${TEMP_DIR}/pass_${comp}")"

    local ip="DHCP (check container)"
    if [[ "$dtype" == "lxc" && "$vmid" != "N/A" ]]; then
      ip=$(pct exec "$vmid" -- hostname -I 2>/dev/null | awk '{print $1}') || ip="DHCP"
    fi

    echo -e "  ${CY}${name}${CL} (${dtype^^} #${vmid})"
    echo -e "    IP:    ${ip}"
    echo -e "    Ports: ${ports}"
    echo -e "    Pass:  ${password}"
    echo ""
  done

  echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
  echo -e "  ${CY}Default Credentials:${CL}"
  echo -e "    Wazuh:    admin / admin (change on first login)"
  echo -e "    TheHive:  admin@thehive.local / secret"
  echo -e "    Cortex:   (set during first-run wizard)"
  echo -e "    MISP:     admin@admin.test / admin"
  echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
  echo ""
  if [[ "$INSTALL_DASHBOARDS" == "yes" ]]; then
    local dash_vmid="N/A"
    [[ -f "${TEMP_DIR}/vmid_dashboards" ]] && dash_vmid="$(cat "${TEMP_DIR}/vmid_dashboards")"
    local dash_pass="N/A"
    [[ -f "${TEMP_DIR}/pass_dashboards" ]] && dash_pass="$(cat "${TEMP_DIR}/pass_dashboards")"
    local dash_ip="DHCP"
    if [[ "$dash_vmid" != "N/A" ]]; then
      dash_ip=$(pct exec "$dash_vmid" -- hostname -I 2>/dev/null | awk '{print $1}') || dash_ip="DHCP"
    fi

    echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
    echo -e "  ${CY}Custom Dashboards${CL} (${DASHBOARD_DEPLOY^^} #${dash_vmid})"
    echo -e "    IP:             ${dash_ip}"
    echo -e "    Bro Hunter:     http://${dash_ip}/bro-hunter/"
    echo -e "    Playbook Forge: http://${dash_ip}/playbook-forge/"
    echo -e "    Pass:           ${dash_pass}"
    echo ""
  fi

  echo -e "  Log file:    ${CY}${LOG_FILE}${CL}"
  echo -e "  Integration: ${CY}bash /root/s3-integrate.sh${CL}"
  echo ""

  {
    echo "S³ Stack Installation Summary"
    echo "Generated: $(date)"
    echo ""
    for i in "${!SELECTED_COMPONENTS[@]}"; do
      local comp="${SELECTED_COMPONENTS[$i]}"
      local vmid="N/A"
      [[ -f "${TEMP_DIR}/vmid_${comp}" ]] && vmid="$(cat "${TEMP_DIR}/vmid_${comp}")"
      echo "${COMP_NAMES[$comp]}: VMID=${vmid}"
    done
    if [[ "$INSTALL_DASHBOARDS" == "yes" ]]; then
      local d_vmid="N/A"
      [[ -f "${TEMP_DIR}/vmid_dashboards" ]] && d_vmid="$(cat "${TEMP_DIR}/vmid_dashboards")"
      echo "Dashboards (Bro Hunter + Playbook Forge): VMID=${d_vmid}"
    fi
  } > /root/s3-stack-summary.txt

  msg_ok "Summary saved to /root/s3-stack-summary.txt"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  clear

  echo -e "${CY}"
  cat << 'BANNER'
    ____        _                             _        ____ _____
   / ___|  ___ | | ___  _ __ ___   ___  _ __ ( )___   / ___|___ /
   \___ \ / _ \| |/ _ \| '_ ` _ \ / _ \| '_ \|// __| | \___ \ |_ \
    ___) | (_) | | (_) | | | | | | (_) | | | | \__ \  ___) |__) |
   |____/ \___/|_|\___/|_| |_| |_|\___/|_| |_| |___/ |____/____/

BANNER
  echo -e "${CL}"
  echo -e "  ${GN}S³ Stack Installer v${SCRIPT_VERSION}${CL}"
  echo -e "  ${CY}SOC in a Box for Proxmox VE${CL}"
  echo ""

  log "=== S³ Stack Installer v${SCRIPT_VERSION} started ==="

  check_root
  check_proxmox
  check_dependencies

  TEMP_DIR="$(mktemp -d)"
  log "Temp directory: $TEMP_DIR"

  show_splash
  select_components
  select_deploy_type
  select_preset
  select_network
  select_storage
  ask_mcp
  ask_dashboards
  show_confirmation

  echo ""
  msg_info "Starting S³ Stack deployment"
  echo ""

  ensure_template "local"

  for i in "${!SELECTED_COMPONENTS[@]}"; do
    local comp="${SELECTED_COMPONENTS[$i]}"
    local dtype="${COMPONENT_TYPES[$i]}"
    local vmid
    vmid="$(get_next_vmid)"

    echo "$vmid" > "${TEMP_DIR}/vmid_${comp}"

    if [[ "$dtype" == "lxc" ]]; then
      local password
      password="$(create_lxc "$comp" "$vmid")"
      echo "$password" > "${TEMP_DIR}/pass_${comp}"
      install_component "$comp" "$vmid" "$dtype"
    else
      create_vm "$comp" "$vmid"
      msg_warn "${COMP_NAMES[$comp]} VM created but requires manual OS install"
    fi
  done

  setup_firewall

  if [[ ${#SELECTED_COMPONENTS[@]} -gt 1 ]]; then
    msg_info "Downloading integration script"
    wget -qO "${TEMP_DIR}/integrate.sh" "${REPO_URL}/scripts/setup/integrate.sh" 2>/dev/null || true
    if [[ -f "${TEMP_DIR}/integrate.sh" && -s "${TEMP_DIR}/integrate.sh" ]]; then
      cp "${TEMP_DIR}/integrate.sh" /root/s3-integrate.sh
      chmod +x /root/s3-integrate.sh
      msg_ok "Integration script saved to /root/s3-integrate.sh"
    fi
  fi

  if [[ "$INSTALL_MCP" == "yes" ]]; then
    msg_info "MCP server installation"
    msg_warn "MCP servers require Node.js 18+. Install separately from the soc-stack repo."
  fi

  # ── Deploy Custom Dashboards (Bro Hunter + Playbook Forge) ────────────────
  if [[ "$INSTALL_DASHBOARDS" == "yes" ]]; then
    msg_info "Deploying S³ Stack Dashboards (Bro Hunter + Playbook Forge)"

    local dash_vmid
    dash_vmid="$(get_next_vmid)"
    echo "$dash_vmid" > "${TEMP_DIR}/vmid_dashboards"

    if [[ "$DASHBOARD_DEPLOY" == "lxc" ]]; then
      # Create LXC with dashboard-appropriate resources (1GB RAM, 15GB disk, 2 cores)
      local dash_hostname="s3-dashboards"
      local dash_pass
      dash_pass="$(openssl rand -base64 12 2>/dev/null || echo 's3dashboards')"

      msg_info "Creating LXC container for dashboards (ID: ${dash_vmid})"

      local template
      template="$(ls /var/lib/vz/template/cache/debian-12-standard* 2>/dev/null | head -1)"
      [[ -z "$template" ]] && template="$(ls /var/lib/vz/template/cache/ubuntu-24* 2>/dev/null | head -1)"

      local net_config="name=eth0,bridge=${BRIDGE}"
      [[ -n "$VLAN_TAG" ]] && net_config+=",tag=${VLAN_TAG}"
      [[ "$IP_MODE" == "dhcp" ]] && net_config+=",ip=dhcp"

      pct create "$dash_vmid" "$template" \
        --hostname "$dash_hostname" \
        --password "$dash_pass" \
        --storage "$STORAGE" \
        --rootfs "${STORAGE}:15" \
        --memory 1024 \
        --cores 2 \
        --net0 "$net_config" \
        --unprivileged 1 \
        --features nesting=1 \
        --onboot 1 \
        --start 0 &>/dev/null

      echo "$dash_pass" > "${TEMP_DIR}/pass_dashboards"
      msg_ok "Created LXC ${dash_hostname} (ID: ${dash_vmid})"

      pct start "$dash_vmid" &>/dev/null || true
      sleep 5

      # Wait for network
      local retries=0
      while ! pct exec "$dash_vmid" -- ping -c1 -W2 8.8.8.8 &>/dev/null; do
        ((retries++))
        [[ $retries -ge 30 ]] && { msg_warn "Network timeout for dashboards container"; break; }
        sleep 2
      done

      # Push and run install script
      local dash_script="${TEMP_DIR}/dashboards.sh"
      wget -qO "$dash_script" "${REPO_URL}/scripts/setup/components/dashboards.sh" 2>/dev/null || true
      if [[ -f "$dash_script" && -s "$dash_script" ]]; then
        pct push "$dash_vmid" "$dash_script" "/tmp/dashboards.sh" &>/dev/null
        pct exec "$dash_vmid" -- bash "/tmp/dashboards.sh" &>> "$LOG_FILE" || true
      fi

      # Wire Zeek log access if Zeek container exists
      local zeek_vmid_file="${TEMP_DIR}/vmid_zeek"
      if [[ -f "$zeek_vmid_file" ]]; then
        local zeek_vmid
        zeek_vmid="$(cat "$zeek_vmid_file")"
        msg_info "Configuring Zeek log bind mount for dashboards container"
        # Create mount point on host
        local zeek_log_host="/var/lib/lxc/${zeek_vmid}/rootfs/opt/zeek/logs"
        if [[ -d "$zeek_log_host" ]]; then
          pct set "$dash_vmid" -mp0 "${zeek_log_host},mp=/opt/s3-dashboards/zeek-logs,ro=1" &>/dev/null || true
          msg_ok "Zeek logs mounted read-only at /opt/s3-dashboards/zeek-logs"
        else
          msg_warn "Zeek log directory not found yet. Configure bind mount manually after Zeek generates logs."
        fi
      fi

      local dash_ip
      dash_ip=$(pct exec "$dash_vmid" -- hostname -I 2>/dev/null | awk '{print $1}') || dash_ip="DHCP"
      msg_ok "S³ Dashboards deployed at http://${dash_ip}/"
    else
      create_vm "dashboards" "$dash_vmid"
      msg_warn "Dashboards VM created but requires manual OS install and script execution"
    fi
  fi

  generate_summary

  log "=== Installation complete ==="
}

main "$@"
