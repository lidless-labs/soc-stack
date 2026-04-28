#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# SOC Stack - MISP Container Install Script
# Runs INSIDE the LXC container (pushed and executed by ct/misp.sh).
#
# Installs Docker + Compose, pulls the stack from the repo, starts services,
# and runs setup.sh for automated account/API key creation.
# ------------------------------------------------------------------------------

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

REPO_RAW="https://raw.githubusercontent.com/solomonneas/soc-stack/main"
STACK_DIR="/opt/soc-stack/misp"

GN="\033[1;92m" RD="\033[01;31m" CY="\033[36m" CL="\033[m"
CM="${GN}✓${CL}" CROSS="${RD}✗${CL}" INFO="${CY}ℹ${CL}"

msg_info() { echo -e " ${INFO} ${1}..."; }
msg_ok()   { echo -e " ${CM} ${1}"; }
msg_error(){ echo -e " ${CROSS} ${1}"; }

# ── System Prep ───────────────────────────────────────────────────────────────
msg_info "Updating system packages"
apt-get update -qq &>/dev/null
apt-get upgrade -y -qq &>/dev/null
apt-get install -y -qq curl wget ca-certificates gnupg jq &>/dev/null
msg_ok "System updated"

# ── Docker ────────────────────────────────────────────────────────────────────
msg_info "Installing Docker"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
apt-get update -qq &>/dev/null
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin &>/dev/null
systemctl enable --now docker &>/dev/null
msg_ok "Docker installed"

# ── Pull Stack Files ──────────────────────────────────────────────────────────
msg_info "Downloading MISP stack"
mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

for f in docker-compose.yml setup.sh config.env.template deploy.md; do
    wget -qO "$f" "${REPO_RAW}/stacks/misp/${f}" 2>/dev/null
done
chmod +x setup.sh
cp config.env.template .env
ln -sf .env config.env
msg_ok "Stack files downloaded"

# ── Tune InnoDB for container RAM ─────────────────────────────────────────────
TOTAL_RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
if [[ $TOTAL_RAM_MB -le 4096 ]]; then
    INNODB_SIZE="512M"
elif [[ $TOTAL_RAM_MB -le 8192 ]]; then
    INNODB_SIZE="2048M"
else
    INNODB_SIZE="4096M"
fi
sed -i "s/INNODB_BUFFER_POOL_SIZE=.*/INNODB_BUFFER_POOL_SIZE=${INNODB_SIZE}/" .env
msg_ok "InnoDB buffer pool set to ${INNODB_SIZE} (${TOTAL_RAM_MB}MB RAM detected)"

# ── Start Services ────────────────────────────────────────────────────────────
msg_info "Starting Docker Compose stack (MISP takes 2-3 minutes on first boot)"
docker compose up -d &>/dev/null
msg_ok "Stack started"

# ── Run Setup ─────────────────────────────────────────────────────────────────
msg_info "Running automated setup (account, API key)"
./setup.sh 2>&1 | tee -a /var/log/soc-stack-setup.log
msg_ok "Setup complete"

echo ""
msg_ok "MISP installation finished"
echo -e "  ${CY}MISP:${CL}   https://$(hostname -I | awk '{print $1}')"
echo -e "  ${CY}Creds:${CL}  ${STACK_DIR}/api-keys.txt"
echo ""
