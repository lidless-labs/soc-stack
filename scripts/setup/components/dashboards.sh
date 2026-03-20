#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# S³ Stack - Custom Dashboards Installer
# Installs Bro Hunter + Playbook Forge in a shared LXC with nginx reverse proxy
#
# MIT License - Copyright (c) 2024 Solomon Neas
# ------------------------------------------------------------------------------

set -euo pipefail

COMPONENT="Dashboards"
LOG_TAG="[S³:${COMPONENT}]"

# Repo URLs
BROHUNTER_REPO="https://github.com/solomonneas/bro_hunter.git"
PLAYBOOKFORGE_REPO="https://github.com/solomonneas/playbook-forge.git"

# Install paths
INSTALL_DIR="/opt/s3-dashboards"
BROHUNTER_DIR="${INSTALL_DIR}/bro-hunter"
PLAYBOOKFORGE_DIR="${INSTALL_DIR}/playbook-forge"

# Ports
BROHUNTER_PORT=5174
PLAYBOOKFORGE_PORT=5177
NGINX_PORT=80

# ── Colors ────────────────────────────────────────────────────────────────────
GN="\033[1;92m" RD="\033[01;31m" YW="\033[33m" CY="\033[36m" CL="\033[m"
CM="${GN}✓${CL}" CROSS="${RD}✗${CL}" INFO="${CY}ℹ${CL}"

msg_info() { echo -e " ${INFO} ${LOG_TAG} ${1}..."; }
msg_ok()   { echo -e " ${CM} ${LOG_TAG} ${1}"; }
msg_error(){ echo -e " ${CROSS} ${LOG_TAG} ${1}"; }

# ── Idempotency Check ────────────────────────────────────────────────────────
if [[ -d "$BROHUNTER_DIR" && -d "$PLAYBOOKFORGE_DIR" ]]; then
  if systemctl is-active --quiet s3-bro-hunter 2>/dev/null && \
     systemctl is-active --quiet s3-playbook-forge 2>/dev/null; then
    msg_ok "Dashboards already installed and running (skipping)"
    exit 0
  fi
fi

# ── System Prep ───────────────────────────────────────────────────────────────
msg_info "Updating system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq &>/dev/null
apt-get upgrade -y -qq &>/dev/null
msg_ok "System updated"

msg_info "Installing prerequisites"
apt-get install -y -qq curl git nginx python3 python3-pip python3-venv &>/dev/null
msg_ok "Prerequisites installed"

# ── Install Node.js 20 ───────────────────────────────────────────────────────
if ! command -v node &>/dev/null || [[ "$(node -v | cut -d. -f1 | tr -d v)" -lt 20 ]]; then
  msg_info "Installing Node.js 20"
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - &>/dev/null
  apt-get install -y -qq nodejs &>/dev/null
  msg_ok "Node.js $(node -v) installed"
else
  msg_ok "Node.js $(node -v) already installed"
fi

# ── Create install directory ──────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"

# ── Install Bro Hunter ───────────────────────────────────────────────────────
msg_info "Cloning Bro Hunter"
if [[ -d "$BROHUNTER_DIR" ]]; then
  cd "$BROHUNTER_DIR" && git pull --quiet &>/dev/null
else
  git clone --quiet "$BROHUNTER_REPO" "$BROHUNTER_DIR" &>/dev/null
fi
msg_ok "Bro Hunter cloned"

msg_info "Building Bro Hunter"
cd "$BROHUNTER_DIR"
npm install --silent &>/dev/null
npm run build &>/dev/null
msg_ok "Bro Hunter built"

# ── Install Playbook Forge ───────────────────────────────────────────────────
msg_info "Cloning Playbook Forge"
if [[ -d "$PLAYBOOKFORGE_DIR" ]]; then
  cd "$PLAYBOOKFORGE_DIR" && git pull --quiet &>/dev/null
else
  git clone --quiet "$PLAYBOOKFORGE_REPO" "$PLAYBOOKFORGE_DIR" &>/dev/null
fi
msg_ok "Playbook Forge cloned"

msg_info "Building Playbook Forge frontend"
cd "${PLAYBOOKFORGE_DIR}/web"
npm install --silent &>/dev/null
npm run build &>/dev/null
msg_ok "Playbook Forge frontend built"

msg_info "Setting up Playbook Forge API"
cd "${PLAYBOOKFORGE_DIR}"
python3 -m venv "${PLAYBOOKFORGE_DIR}/venv" &>/dev/null
"${PLAYBOOKFORGE_DIR}/venv/bin/pip" install --quiet fastapi uvicorn &>/dev/null
msg_ok "Playbook Forge API configured"

# ── Systemd Services ─────────────────────────────────────────────────────────
msg_info "Creating systemd services"

# Bro Hunter: serve built frontend with vite preview
cat > /etc/systemd/system/s3-bro-hunter.service <<EOF
[Unit]
Description=S³ Stack - Bro Hunter
After=network.target

[Service]
Type=simple
WorkingDirectory=${BROHUNTER_DIR}
ExecStart=$(which npx) vite preview --host 0.0.0.0 --port ${BROHUNTER_PORT}
Restart=always
RestartSec=5
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

# Playbook Forge: FastAPI backend + static frontend served by nginx
cat > /etc/systemd/system/s3-playbook-forge.service <<EOF
[Unit]
Description=S³ Stack - Playbook Forge API
After=network.target

[Service]
Type=simple
WorkingDirectory=${PLAYBOOKFORGE_DIR}
ExecStart=${PLAYBOOKFORGE_DIR}/venv/bin/uvicorn api.main:app --host 0.0.0.0 --port ${PLAYBOOKFORGE_PORT}
Restart=always
RestartSec=5
Environment=PYTHONPATH=${PLAYBOOKFORGE_DIR}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now s3-bro-hunter &>/dev/null
systemctl enable --now s3-playbook-forge &>/dev/null
msg_ok "Systemd services created and started"

# ── Nginx Reverse Proxy ──────────────────────────────────────────────────────
msg_info "Configuring nginx reverse proxy"

cat > /etc/nginx/sites-available/s3-dashboards <<EOF
# S³ Stack - Custom Dashboards
# Bro Hunter:     /bro-hunter/
# Playbook Forge: /playbook-forge/

server {
    listen ${NGINX_PORT} default_server;
    server_name _;

    # Landing page
    location = / {
        default_type text/html;
        return 200 '<!DOCTYPE html>
<html>
<head><title>S³ Stack Dashboards</title>
<style>
  body { font-family: system-ui; background: #0f172a; color: #e2e8f0; display: flex; flex-direction: column; align-items: center; justify-content: center; min-height: 100vh; margin: 0; }
  h1 { font-size: 2rem; margin-bottom: 2rem; }
  .tools { display: flex; gap: 2rem; }
  a { background: #1e293b; border: 1px solid #334155; padding: 2rem 3rem; border-radius: 12px; color: #7dd3fc; text-decoration: none; font-size: 1.2rem; transition: all 0.2s; }
  a:hover { border-color: #7dd3fc; background: #1e3a5f; }
  .sub { color: #64748b; font-size: 0.85rem; margin-top: 0.5rem; }
</style>
</head>
<body>
  <h1>S&sup3; Stack Dashboards</h1>
  <div class="tools">
    <a href="/bro-hunter/">Bro Hunter<div class="sub">Zeek Log Analysis</div></a>
    <a href="/playbook-forge/">Playbook Forge<div class="sub">IR Playbook Builder</div></a>
  </div>
</body>
</html>';
    }

    # Bro Hunter (static build served by vite preview)
    location /bro-hunter/ {
        proxy_pass http://127.0.0.1:${BROHUNTER_PORT}/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # Playbook Forge (static frontend)
    location /playbook-forge/ {
        alias ${PLAYBOOKFORGE_DIR}/web/dist/;
        try_files \$uri \$uri/ /playbook-forge/index.html;
    }

    # Playbook Forge API
    location /playbook-forge/api/ {
        proxy_pass http://127.0.0.1:${PLAYBOOKFORGE_PORT}/api/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# Enable site, disable default
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/s3-dashboards /etc/nginx/sites-enabled/s3-dashboards

nginx -t &>/dev/null && systemctl restart nginx &>/dev/null
msg_ok "Nginx configured and restarted"

# ── Zeek Log Mount Point ─────────────────────────────────────────────────────
# If Zeek logs are available via bind mount, Bro Hunter can read them
ZEEK_LOG_MOUNT="/opt/s3-dashboards/zeek-logs"
mkdir -p "$ZEEK_LOG_MOUNT"
msg_info "Zeek log mount point created at ${ZEEK_LOG_MOUNT}"
msg_ok "Configure bind mount from Zeek container for live log analysis"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
msg_ok "S³ Stack Dashboards installed successfully"
echo ""
echo -e "  ${CY}Bro Hunter:${CL}     http://<container-ip>/bro-hunter/"
echo -e "  ${CY}Playbook Forge:${CL} http://<container-ip>/playbook-forge/"
echo -e "  ${CY}Landing Page:${CL}   http://<container-ip>/"
echo ""
echo -e "  ${CY}Services:${CL}"
echo -e "    systemctl status s3-bro-hunter"
echo -e "    systemctl status s3-playbook-forge"
echo ""
echo -e "  ${CY}Update:${CL}"
echo -e "    cd ${BROHUNTER_DIR} && git pull && npm run build && systemctl restart s3-bro-hunter"
echo -e "    cd ${PLAYBOOKFORGE_DIR} && git pull && cd web && npm run build && systemctl restart s3-playbook-forge"
echo ""
