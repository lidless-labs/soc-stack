#!/usr/bin/env bash
# scripts/components/zeek-suricata/deploy.sh
# Runs INSIDE the zeek-suricata LXC. Idempotent. Installs both tools native.
#
# Required env (set by orchestrator via pct exec):
#   SOC_STATE_DIR        - path inside the LXC (e.g. /var/lib/soc-stack)
#   SOC_COMPONENT        - "zeek-suricata"
#   SOC_PRESET           - informational
#   SOC_NON_INTERACTIVE  - "1"
#
# On success: writes ${SOC_STATE_DIR}/state/zeek-suricata.json with status=deployed
# On failure: writes ${SOC_STATE_DIR}/state/zeek-suricata.json with status=failed + error

set -euo pipefail

: "${SOC_STATE_DIR:?SOC_STATE_DIR must be set}"
: "${SOC_COMPONENT:=zeek-suricata}"

STATE_FILE="${SOC_STATE_DIR}/state/${SOC_COMPONENT}.json"
SECRETS_DIR="${SOC_STATE_DIR}/secrets"
mkdir -p "${SOC_STATE_DIR}/state" "${SECRETS_DIR}"

log() { printf '[zs-deploy] %s\n' "$*"; }

write_failed() {
  local err="$1"
  jq -n --arg err "${err}" '{component:"zeek-suricata",status:"failed",error:$err}' > "${STATE_FILE}"
  log "FAILED: ${err}"
  exit 1
}

trap 'write_failed "aborted on line $LINENO"' ERR

# Idempotency: both services up?
if systemctl is-active --quiet zeek 2>/dev/null \
   && systemctl is-active --quiet suricata 2>/dev/null; then
  log "both services already running, refreshing state"
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl wget gnupg software-properties-common jq

# --- Install Zeek (official package repo) ---
if ! command -v zeek >/dev/null 2>&1; then
  log "installing Zeek from openSUSE Build Service repo"
  # shellcheck disable=SC2086
  echo 'deb [signed-by=/etc/apt/trusted.gpg.d/security_zeek.gpg] http://download.opensuse.org/repositories/security:/zeek/xUbuntu_22.04/ /' \
    > /etc/apt/sources.list.d/security_zeek.list
  curl -fsSL https://download.opensuse.org/repositories/security:zeek/xUbuntu_22.04/Release.key \
    | gpg --dearmor -o /etc/apt/trusted.gpg.d/security_zeek.gpg
  apt-get update -qq
  apt-get install -y -qq zeek-lts
fi
export PATH="/opt/zeek/bin:${PATH}"
# shellcheck disable=SC2016
echo 'export PATH="/opt/zeek/bin:$PATH"' > /etc/profile.d/zeek.sh

IFACE="$(ip route show default | awk '{print $5}' | head -1)"
IFACE="${IFACE:-eth0}"

# Configure Zeek node.cfg
if [[ -f /opt/zeek/etc/node.cfg ]]; then
  cat > /opt/zeek/etc/node.cfg <<EOF
[zeek]
type=standalone
host=localhost
interface=${IFACE}
EOF
fi
zeekctl deploy >/dev/null 2>&1 || true
systemctl enable --now zeek.service 2>/dev/null || true

# --- Install Suricata (PPA) ---
if ! command -v suricata >/dev/null 2>&1; then
  log "installing Suricata from oisf/suricata-stable PPA"
  add-apt-repository -y ppa:oisf/suricata-stable
  apt-get update -qq
  apt-get install -y -qq suricata suricata-update
fi
if [[ -f /etc/suricata/suricata.yaml ]]; then
  sed -i "s/- interface: eth0/- interface: ${IFACE}/" /etc/suricata/suricata.yaml
fi
suricata-update >/dev/null 2>&1 || true
systemctl enable --now suricata 2>/dev/null || true

IP="$(hostname -I | awk '{print $1}')"

jq -n \
  --arg ip "${IP}" \
  --arg iface "${IFACE}" \
  '{
    component: "zeek-suricata",
    status: "deployed",
    interface: $iface,
    zeek: {
      log_dir: "/opt/zeek/logs/current",
      config_dir: "/opt/zeek/etc"
    },
    suricata: {
      eve_path: "/var/log/suricata/eve.json",
      rules_dir: "/var/lib/suricata/rules",
      config: "/etc/suricata/suricata.yaml"
    },
    services: ["zeek","suricata"],
    host_ip: $ip
  }' > "${STATE_FILE}"

log "zeek + suricata deploy complete (iface=${IFACE})"
trap - ERR
