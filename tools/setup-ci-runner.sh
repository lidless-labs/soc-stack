#!/usr/bin/env bash
# tools/setup-ci-runner.sh
# One-shot bootstrap for the soc-stack CI runner on a Proxmox host.
#
# What it does:
#   1. Creates an unprivileged LXC `gh-runner-soc-stack` (VMID 119 by default)
#      with Ubuntu 22.04, 4 GB RAM, 30 GB disk, 2 cores
#   2. Generates an ed25519 SSH key inside the LXC
#   3. Creates a `gh-runner` user on the Proxmox host with the LXC's public key
#      authorized, and a sudoers entry scoped to pct, qm, pvesm, pveam only
#   4. Installs the github-actions-runner inside the LXC
#   5. Drops a test reaper cron on the Proxmox host
#
# Required env (must be set before running):
#   GITHUB_RUNNER_TOKEN  - registration token from
#                         https://github.com/solomonneas/soc-stack/settings/actions/runners/new
#   (optional) RUNNER_VMID  - VMID to use (default: 119)
#   (optional) RUNNER_BRIDGE - bridge for the runner LXC (default: vmbr0)
#   (optional) RUNNER_STORAGE - storage pool (default: local-lvm)

set -euo pipefail

VMID="${RUNNER_VMID:-119}"
BRIDGE="${RUNNER_BRIDGE:-vmbr0}"
STORAGE="${RUNNER_STORAGE:-local-lvm}"
HOSTNAME="gh-runner-soc-stack"

if [[ -z "${GITHUB_RUNNER_TOKEN:-}" ]]; then
  cat <<EOF >&2
GITHUB_RUNNER_TOKEN env var is required.
Get a token here (it expires in 1 hour):
  https://github.com/solomonneas/soc-stack/settings/actions/runners/new
Then:
  export GITHUB_RUNNER_TOKEN=<token>
  sudo -E bash tools/setup-ci-runner.sh
EOF
  exit 1
fi

[[ ${EUID} -eq 0 ]] || { echo "must run as root on the Proxmox host" >&2; exit 1; }
command -v pct >/dev/null || { echo "pct not found - not a Proxmox host?" >&2; exit 1; }

log() { printf '[setup-ci-runner] %s\n' "$*"; }

# ---- 1. Create the LXC ----
if pct status "${VMID}" >/dev/null 2>&1; then
  log "LXC ${VMID} already exists, skipping create"
else
  log "creating LXC ${VMID} (${HOSTNAME}) on ${BRIDGE}/${STORAGE}"
  TEMPLATE="$(pveam list local | awk '/ubuntu-22.04/{print $1; exit}')"
  if [[ -z "${TEMPLATE}" ]]; then
    log "downloading Ubuntu 22.04 template"
    pveam update >/dev/null 2>&1 || true
    pveam download local ubuntu-22.04-standard_22.04-1_amd64.tar.zst
    TEMPLATE="local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
  fi

  ROOTPW="$(LC_ALL=C tr -dc 'A-Za-z0-9_+=.-' </dev/urandom | head -c 24)"
  pct create "${VMID}" "${TEMPLATE}" \
    --hostname "${HOSTNAME}" \
    --memory 4096 --cores 2 \
    --rootfs "${STORAGE}:30" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --unprivileged 1 --features nesting=1 \
    --onboot 1 --start 0 \
    --password "${ROOTPW}"
  pct start "${VMID}"
  log "LXC ${VMID} created and started"
fi

# Wait for network
log "waiting for LXC network"
for _ in $(seq 1 60); do
  if pct exec "${VMID}" -- ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; then break; fi
  sleep 2
done

# ---- 2. SSH key inside the LXC ----
if ! pct exec "${VMID}" -- test -f /root/.ssh/id_ed25519; then
  log "generating SSH key inside LXC ${VMID}"
  pct exec "${VMID}" -- bash -c "mkdir -p /root/.ssh && chmod 700 /root/.ssh && ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519 -C 'gh-runner-soc-stack@$(hostname)'"
fi
RUNNER_PUBKEY="$(pct exec "${VMID}" -- cat /root/.ssh/id_ed25519.pub)"

# ---- 3. gh-runner user on the Proxmox host ----
if ! id gh-runner >/dev/null 2>&1; then
  log "creating gh-runner user on Proxmox host"
  useradd -m -s /bin/bash -c "GitHub Actions runner for soc-stack" gh-runner
fi
install -d -m 700 -o gh-runner -g gh-runner /home/gh-runner/.ssh
echo "${RUNNER_PUBKEY}" > /home/gh-runner/.ssh/authorized_keys
chmod 600 /home/gh-runner/.ssh/authorized_keys
chown gh-runner:gh-runner /home/gh-runner/.ssh/authorized_keys

# Sudoers entry - scoped to pct/qm/pvesm/pveam only
SUDOFILE="/etc/sudoers.d/gh-runner-soc-stack"
cat > "${SUDOFILE}" <<'EOF'
# Scoped sudoer for the soc-stack CI runner.
# Only allows the four binaries needed to manage test LXCs/VMs.
gh-runner ALL=(root) NOPASSWD: /usr/sbin/pct, /usr/sbin/qm, /usr/sbin/pvesm, /usr/sbin/pveam
Defaults:gh-runner !requiretty
EOF
chmod 0440 "${SUDOFILE}"
visudo -c -f "${SUDOFILE}" >/dev/null

# ---- 3b. SSH plumbing for the `runner` user inside the LXC ----
PROXMOX_HOST_IP="$(hostname -I | awk '{print $1}')"
log "wiring SSH from runner user to ${PROXMOX_HOST_IP} (alias 'proxmox')"

# /etc/hosts inside the runner LXC (idempotent)
if ! pct exec "${VMID}" -- grep -qE "^[0-9.]+[[:space:]]+proxmox([[:space:]]|\$)" /etc/hosts; then
  pct exec "${VMID}" -- bash -c "echo '${PROXMOX_HOST_IP} proxmox' >> /etc/hosts"
fi

# Copy the SSH key to /home/runner/.ssh and write the SSH config
pct exec "${VMID}" -- bash -c '
  useradd -m -s /bin/bash runner 2>/dev/null || true
  install -d -m 0700 -o runner -g runner /home/runner/.ssh
  cp /root/.ssh/id_ed25519 /home/runner/.ssh/id_ed25519
  cp /root/.ssh/id_ed25519.pub /home/runner/.ssh/id_ed25519.pub
  chmod 600 /home/runner/.ssh/id_ed25519
  chmod 644 /home/runner/.ssh/id_ed25519.pub
  chown runner:runner /home/runner/.ssh/id_ed25519 /home/runner/.ssh/id_ed25519.pub

  cat > /home/runner/.ssh/config <<SSHEOF
Host proxmox
  HostName proxmox
  User gh-runner
  IdentityFile /home/runner/.ssh/id_ed25519
  StrictHostKeyChecking accept-new
SSHEOF
  chmod 600 /home/runner/.ssh/config
  chown runner:runner /home/runner/.ssh/config
'

# ---- 4. github-actions-runner inside the LXC ----
if ! pct exec "${VMID}" -- test -f /home/runner/.runner; then
  log "installing github-actions-runner inside LXC ${VMID}"
  pct exec "${VMID}" -- bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl jq tar libicu70 rsync git
    useradd -m -s /bin/bash runner || true
    install -d -m 0755 -o runner -g runner /home/runner/actions-runner
    cd /home/runner/actions-runner
    LATEST=$(curl -s https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name | sed s/v//)
    curl -fsSLO https://github.com/actions/runner/releases/download/v${LATEST}/actions-runner-linux-x64-${LATEST}.tar.gz
    tar xzf actions-runner-linux-x64-${LATEST}.tar.gz
    rm actions-runner-linux-x64-${LATEST}.tar.gz
    chown -R runner:runner /home/runner/actions-runner
  '
  pct exec "${VMID}" -- sudo -u runner bash -c "
    cd /home/runner/actions-runner
    ./config.sh --unattended --replace \
      --url https://github.com/solomonneas/soc-stack \
      --token '${GITHUB_RUNNER_TOKEN}' \
      --name 'soc-stack-proxmox-host' \
      --labels 'self-hosted,soc-stack,proxmox' \
      --work _work
  "
  pct exec "${VMID}" -- bash -c "cd /home/runner/actions-runner && ./svc.sh install runner && ./svc.sh start"
fi

# ---- 5. test reaper cron on the Proxmox host ----
log "installing soc-stack-test-reaper.sh cron"
install -m 0755 /root/soc-stack/tools/soc-stack-test-reaper.sh /usr/local/bin/soc-stack-test-reaper.sh
cat > /etc/cron.d/soc-stack-test-reaper <<'EOF'
# soc-stack: destroy any test LXCs in VMID range 9000-9099 older than 90 minutes
*/15 * * * * root /usr/local/bin/soc-stack-test-reaper.sh >/dev/null 2>&1
EOF
chmod 0644 /etc/cron.d/soc-stack-test-reaper

log "done. runner LXC=${VMID}, labels=[self-hosted,soc-stack,proxmox]"
log "verify: gh api repos/solomonneas/soc-stack/actions/runners --jq '.runners[] | {name, status, labels: [.labels[].name]}'"
