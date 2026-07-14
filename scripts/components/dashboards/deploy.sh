#!/usr/bin/env bash
# scripts/components/dashboards/deploy.sh
# Runs INSIDE the dashboards LXC. Idempotent. Installs Bro Hunter + Playbook Forge
# with nginx reverse proxy.
#
# Required env (set by orchestrator via pct exec):
#   SOC_STATE_DIR        - path inside the LXC (e.g. /var/lib/soc-stack)
#   SOC_COMPONENT        - "dashboards"
#   SOC_PRESET           - informational
#   SOC_NON_INTERACTIVE  - "1"
#
# On success: writes ${SOC_STATE_DIR}/state/dashboards.json with status=deployed
# On failure: writes ${SOC_STATE_DIR}/state/dashboards.json with status=failed + error

set -euo pipefail

: "${SOC_STATE_DIR:?SOC_STATE_DIR must be set}"
: "${SOC_COMPONENT:=dashboards}"

STATE_FILE="${SOC_STATE_DIR}/state/${SOC_COMPONENT}.json"
SECRETS_DIR="${SOC_STATE_DIR}/secrets"
mkdir -p "${SOC_STATE_DIR}/state" "${SECRETS_DIR}"

log() { printf '[dash-deploy] %s\n' "$*"; }

write_failed() {
  local err="$1"
  jq -n --arg err "${err}" '{component:"dashboards",status:"failed",error:$err}' > "${STATE_FILE}"
  log "FAILED: ${err}"
  exit 1
}

trap 'write_failed "aborted on line $LINENO"' ERR

# Repo + path constants. Sources are pinned to a commit (supply-chain: a
# compromised upstream cannot change what gets built). Bump deliberately.
# bro-hunter was renamed to lidless-labs/vervet; the old solomonneas URL only
# still worked via GitHub's rename redirect.
BROHUNTER_REPO="https://github.com/lidless-labs/vervet.git"
BROHUNTER_REF="ceb99a4f4a4292010a6a6c6f7915cadf7d2c070c"
# playbook-forge no longer resolves at its old URL (the dashboards deploy was
# failing to clone it). Its successor is lidless-labs/hotwash - a visual
# IR-playbook builder with the same web/ Vite layout. VERIFY this is the
# intended source before the next release.
PLAYBOOKFORGE_REPO="https://github.com/lidless-labs/hotwash.git"
PLAYBOOKFORGE_REF="162543435d75b3ca859eae41b5cf403d833fe744"
INSTALL_DIR="/opt/s3-dashboards"
BROHUNTER_DIR="${INSTALL_DIR}/bro-hunter"
PLAYBOOKFORGE_DIR="${INSTALL_DIR}/playbook-forge"
BROHUNTER_PORT=5174
PLAYBOOKFORGE_PORT=5177

# Idempotency: both services active AND nginx active?
if systemctl is-active --quiet s3-bro-hunter 2>/dev/null \
   && systemctl is-active --quiet s3-playbook-forge 2>/dev/null \
   && systemctl is-active --quiet nginx 2>/dev/null; then
  log "all services already running, refreshing state"
  IP="$(hostname -I | awk '{print $1}')"
  jq -n \
    --arg ip "${IP}" \
    --argjson bh_port "${BROHUNTER_PORT}" \
    --argjson pf_port "${PLAYBOOKFORGE_PORT}" \
    '{
      component: "dashboards",
      status: "deployed",
      host_ip: $ip,
      bro_hunter_url: ("http://" + $ip + "/bro-hunter/"),
      playbook_forge_url: ("http://" + $ip + "/playbook-forge/"),
      services: ["nginx","s3-bro-hunter","s3-playbook-forge"]
    }' > "${STATE_FILE}"
  trap - ERR
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
log "updating apt"
apt-get update -qq
apt-get install -y -qq nginx git python3-venv curl jq

# Install Node 20 from NodeSource if not already present or too old
if ! command -v node >/dev/null 2>&1 || [[ "$(node -v | cut -d. -f1 | tr -d v)" -lt 20 ]]; then
  log "installing Node.js 20 from NodeSource"
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y -qq nodejs
fi
log "node $(node -v), npm $(npm -v)"

mkdir -p "${INSTALL_DIR}"

# Clone or update Bro Hunter
if [[ -d "${BROHUNTER_DIR}/.git" ]]; then
  log "updating Bro Hunter"
  git -C "${BROHUNTER_DIR}" fetch --quiet origin
else
  log "cloning Bro Hunter"
  git clone --quiet "${BROHUNTER_REPO}" "${BROHUNTER_DIR}"
fi
git -C "${BROHUNTER_DIR}" checkout --quiet --detach "${BROHUNTER_REF}"
# vervet keeps package.json at the repo ROOT (its Vite app lives under web/ with
# root:web/, outDir:dist -> web/dist). Install at root, then build via the web
# config, skipping tsc (upstream has unused-var typecheck errors). Verified this
# produces web/dist locally against the pinned commit.
log "building Bro Hunter"
( cd "${BROHUNTER_DIR}" && npm install --silent && npx --yes vite build --config web/vite.config.ts )

# Clone or update Playbook Forge
if [[ -d "${PLAYBOOKFORGE_DIR}/.git" ]]; then
  log "updating Playbook Forge"
  git -C "${PLAYBOOKFORGE_DIR}" fetch --quiet origin
else
  log "cloning Playbook Forge"
  git clone --quiet "${PLAYBOOKFORGE_REPO}" "${PLAYBOOKFORGE_DIR}"
fi
git -C "${PLAYBOOKFORGE_DIR}" checkout --quiet --detach "${PLAYBOOKFORGE_REF}"
# hotwash keeps its Vite app (and package.json) under web/, building to web/dist.
# Verified this produces web/dist locally against the pinned commit.
log "building Playbook Forge"
( cd "${PLAYBOOKFORGE_DIR}/web" && npm install --silent && npx --yes vite build )

# Systemd unit: Bro Hunter (vite preview from web/ subdir)
cat > /etc/systemd/system/s3-bro-hunter.service <<EOF
[Unit]
Description=S3 Stack - Bro Hunter
After=network.target

[Service]
Type=simple
WorkingDirectory=${BROHUNTER_DIR}/web
ExecStart=npx vite preview --port ${BROHUNTER_PORT} --host 127.0.0.1
Restart=on-failure
RestartSec=5
Environment=NODE_ENV=production
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectKernelTunables=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
EOF

# Systemd unit: Playbook Forge (vite preview from web/ subdir)
cat > /etc/systemd/system/s3-playbook-forge.service <<EOF
[Unit]
Description=S3 Stack - Playbook Forge
After=network.target

[Service]
Type=simple
WorkingDirectory=${PLAYBOOKFORGE_DIR}/web
ExecStart=npx vite preview --port ${PLAYBOOKFORGE_PORT} --host 127.0.0.1
Restart=on-failure
RestartSec=5
Environment=NODE_ENV=production
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectKernelTunables=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now s3-bro-hunter
systemctl enable --now s3-playbook-forge
log "systemd services enabled and started"

# Nginx reverse proxy config
cat > /etc/nginx/sites-available/s3-dashboards <<'NGINXEOF'
# S3 Stack - Custom Dashboards
# Bro Hunter:     /bro-hunter/
# Playbook Forge: /playbook-forge/

server {
    listen 80 default_server;
    server_name _;

    location /bro-hunter/ {
        proxy_pass http://127.0.0.1:5174/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /playbook-forge/ {
        proxy_pass http://127.0.0.1:5177/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location / {
        return 200 'S3 Stack Dashboards\n';
        add_header Content-Type text/plain;
    }
}
NGINXEOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/s3-dashboards /etc/nginx/sites-enabled/s3-dashboards
nginx -t && systemctl reload nginx
log "nginx configured"

# Zeek log mount point (populated by integrate.sh bind-mount from Proxmox host)
mkdir -p "${INSTALL_DIR}/zeek-logs"

IP="$(hostname -I | awk '{print $1}')"

jq -n \
  --arg ip "${IP}" \
  '{
    component: "dashboards",
    status: "deployed",
    host_ip: $ip,
    bro_hunter_url: ("http://" + $ip + "/bro-hunter/"),
    playbook_forge_url: ("http://" + $ip + "/playbook-forge/"),
    services: ["nginx","s3-bro-hunter","s3-playbook-forge"]
  }' > "${STATE_FILE}"

log "dashboards deploy complete"
trap - ERR
