#!/usr/bin/env bash
# scripts/components/wazuh/deploy.sh
# Runs INSIDE the Wazuh LXC. Idempotent. Installs Wazuh single-node.
#
# Required env (set by orchestrator via pct exec):
#   SOC_STATE_DIR        - path inside the LXC (e.g. /var/lib/soc-stack);
#                          orchestrator pulls outputs via pct pull after exit
#   SOC_COMPONENT        - "wazuh"
#   SOC_PRESET           - informational
#   SOC_NON_INTERACTIVE  - "1"
#
# On success: writes ${SOC_STATE_DIR}/state/wazuh.json with status=deployed
# On failure: writes ${SOC_STATE_DIR}/state/wazuh.json with status=failed + error

set -euo pipefail

: "${SOC_STATE_DIR:?SOC_STATE_DIR must be set}"
: "${SOC_COMPONENT:=wazuh}"

STATE_FILE="${SOC_STATE_DIR}/state/${SOC_COMPONENT}.json"
SECRETS_DIR="${SOC_STATE_DIR}/secrets"
mkdir -p "${SOC_STATE_DIR}/state" "${SECRETS_DIR}"

log() { printf '[wazuh-deploy] %s\n' "$*"; }

write_failed() {
  local err="$1"
  jq -n --arg err "${err}" '{
    component: "wazuh",
    status: "failed",
    error: $err
  }' > "${STATE_FILE}"
  log "FAILED: ${err}"
  exit 1
}

trap 'write_failed "deploy.sh aborted on line $LINENO"' ERR

# Idempotency: if services are already running, refresh state and exit 0
if systemctl is-active --quiet wazuh-manager 2>/dev/null \
   && systemctl is-active --quiet wazuh-indexer 2>/dev/null \
   && systemctl is-active --quiet wazuh-dashboard 2>/dev/null; then
  log "Wazuh already installed and running, refreshing state"

  IP="$(hostname -I | awk '{print $1}')"
  ADMIN_PASS=""
  if [[ -f "${SECRETS_DIR}/wazuh-admin.txt" ]]; then
    ADMIN_PASS="$(cat "${SECRETS_DIR}/wazuh-admin.txt")"
  fi

  jq -n \
    --arg ip "${IP}" \
    --arg pass "${ADMIN_PASS}" \
    '{
      component: "wazuh",
      status: "deployed",
      url: ("https://" + $ip),
      api_url: ("https://" + $ip + ":55000"),
      agent_endpoint: ($ip + ":1515"),
      credentials: { user: "admin", password: $pass },
      services: ["wazuh-manager","wazuh-indexer","wazuh-dashboard"]
    }' > "${STATE_FILE}"
  exit 0
fi

# Fresh install

# Wazuh-install hardware check: required on minimal preset (2GB/1c), not needed
# on standard (4GB/2c) or production (8GB/4c) which already meet the upstream
# 4GB/2c floor.
WAZUH_INSTALL_FLAGS=""
if [[ "${SOC_PRESET:-standard}" == "minimal" ]]; then
  WAZUH_INSTALL_FLAGS="-i"
  log "preset=minimal: passing -i to wazuh-install.sh to skip hardware check"
fi

log "Updating apt"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl wget gnupg jq

log "Downloading Wazuh installer"
cd /root
curl -fsSLO https://packages.wazuh.com/4.9/wazuh-install.sh
# Always write our own config.yml; the upstream URL serves a template with
# placeholder IPs that cause wazuh-install.sh --generate-config-files to fail.
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

log "Running wazuh-install.sh (this may take 10-20 minutes)"
# shellcheck disable=SC2086
bash wazuh-install.sh ${WAZUH_INSTALL_FLAGS} --generate-config-files
# shellcheck disable=SC2086
bash wazuh-install.sh ${WAZUH_INSTALL_FLAGS} --wazuh-indexer node-1
# shellcheck disable=SC2086
bash wazuh-install.sh ${WAZUH_INSTALL_FLAGS} --start-cluster
# shellcheck disable=SC2086
bash wazuh-install.sh ${WAZUH_INSTALL_FLAGS} --wazuh-server wazuh-1
# shellcheck disable=SC2086
bash wazuh-install.sh ${WAZUH_INSTALL_FLAGS} --wazuh-dashboard dashboard

# Extract the generated admin password from wazuh-passwords.txt
ADMIN_PASS=""
if [[ -f /root/wazuh-install-files.tar ]]; then
  tar -xf /root/wazuh-install-files.tar -C /tmp/
  if [[ -f /tmp/wazuh-install-files/wazuh-passwords.txt ]]; then
    ADMIN_PASS="$(grep -A1 "username: 'admin'" /tmp/wazuh-install-files/wazuh-passwords.txt | grep password | awk -F\' '{print $2}')"
  fi
fi
ADMIN_PASS="${ADMIN_PASS:-admin}"

# Store the password
printf '%s' "${ADMIN_PASS}" > "${SECRETS_DIR}/wazuh-admin.txt"
chmod 600 "${SECRETS_DIR}/wazuh-admin.txt"

# Verify services
for svc in wazuh-manager wazuh-indexer wazuh-dashboard; do
  if ! systemctl is-active --quiet "${svc}"; then
    write_failed "${svc} did not start"
  fi
done

IP="$(hostname -I | awk '{print $1}')"

jq -n \
  --arg ip "${IP}" \
  --arg pass "${ADMIN_PASS}" \
  '{
    component: "wazuh",
    status: "deployed",
    url: ("https://" + $ip),
    api_url: ("https://" + $ip + ":55000"),
    agent_endpoint: ($ip + ":1515"),
    credentials: { user: "admin", password: $pass },
    services: ["wazuh-manager","wazuh-indexer","wazuh-dashboard"]
  }' > "${STATE_FILE}"

log "Wazuh deployment complete: https://${IP}"
trap - ERR
