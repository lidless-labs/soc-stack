#!/usr/bin/env bash
# scripts/components/mcp/deploy.sh
# Runs INSIDE the mcp LXC. Idempotent. Installs 9 MCP servers as systemd services.

set -euo pipefail
: "${SOC_STATE_DIR:?}"; : "${SOC_COMPONENT:=mcp}"
STATE_FILE="${SOC_STATE_DIR}/state/${SOC_COMPONENT}.json"
SECRETS_DIR="${SOC_STATE_DIR}/secrets"
INSTALL_DIR="/opt/soc-mcp"
mkdir -p "${SOC_STATE_DIR}/state" "${SECRETS_DIR}" "${INSTALL_DIR}"

log() { printf '[mcp-deploy] %s\n' "$*"; }
write_failed() {
  jq -n --arg err "$1" '{component:"mcp",status:"failed",error:$err}' > "${STATE_FILE}"
  log "FAILED: $1"; exit 1
}
trap 'write_failed "aborted on line $LINENO"' ERR

# Server inventory: name | repo | port | env-key-list
# env-key-list documents what env vars integrate.sh will populate later.
declare -A SERVERS=(
  [wazuh]="https://github.com/solomonneas/wazuh-mcp.git|3001|WAZUH_URL,WAZUH_USER,WAZUH_PASSWORD"
  [thehive]="https://github.com/solomonneas/thehive-mcp.git|3002|THEHIVE_URL,THEHIVE_API_KEY"
  [cortex]="https://github.com/solomonneas/cortex-mcp.git|3003|CORTEX_URL,CORTEX_API_KEY"
  [misp]="https://github.com/solomonneas/misp-mcp.git|3004|MISP_URL,MISP_API_KEY"
  [zeek]="https://github.com/solomonneas/zeek-mcp.git|3005|ZEEK_LOG_DIR,ZEEK_LOG_FORMAT"
  [suricata]="https://github.com/solomonneas/suricata-mcp.git|3006|SURICATA_EVE_PATH"
  [mitre]="https://github.com/solomonneas/mitre-mcp.git|3007|MITRE_DATA_DIR"
  [rapid7]="https://github.com/solomonneas/rapid7-mcp.git|3008|RAPID7_URL,RAPID7_API_KEY"
  [sophos]="https://github.com/solomonneas/sophos-mcp.git|3009|SOPHOS_CLIENT_ID,SOPHOS_CLIENT_SECRET"
)

# Idempotency: every systemd unit active?
all_active=1
for name in "${!SERVERS[@]}"; do
  if ! systemctl is-active --quiet "soc-mcp-${name}" 2>/dev/null; then
    all_active=0; break
  fi
done

export DEBIAN_FRONTEND=noninteractive

if [[ "${all_active}" -eq 0 ]]; then
  log "installing deps"
  apt-get update -qq
  apt-get install -y -qq curl git ca-certificates jq

  # Wait for DNS + connectivity (LXC may not be fully online yet)
  for _ in $(seq 1 30); do
    if curl -sf --max-time 3 https://github.com/ >/dev/null 2>&1; then break; fi
    sleep 2
  done

  if ! command -v node >/dev/null 2>&1 || (( "$(node -v | sed 's/[v.]/ /g' | awk '{print $1}')" < 20 )); then
    log "installing Node.js 20"
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y -qq nodejs
  fi
fi

IP="$(hostname -I | awk '{print $1}')"
ENDPOINTS_JSON='[]'

for name in wazuh thehive cortex misp zeek suricata mitre rapid7 sophos; do
  IFS='|' read -r repo port env_keys <<< "${SERVERS[$name]}"
  dest="${INSTALL_DIR}/${name}-mcp"

  # Token: persisted on first install, reused on idempotent re-runs
  token_file="${SECRETS_DIR}/mcp-${name}-token.txt"
  if [[ -f "${token_file}" ]]; then
    token="$(cat "${token_file}")"
  else
    token="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 40)"
    printf '%s' "${token}" > "${token_file}"
    chmod 600 "${token_file}"
  fi

  # Clone or update repo
  if [[ -d "${dest}/.git" ]]; then
    if git -C "${dest}" fetch --quiet; then
      git -C "${dest}" reset --quiet --hard origin/HEAD || true
    fi
  else
    # Retry git clone up to 3 times
    clone_ok=0
    for attempt in 1 2 3; do
      if git clone --quiet "${repo}" "${dest}"; then
        clone_ok=1; break
      fi
      log "clone attempt ${attempt}/3 failed for ${repo}, retrying in 5s"
      sleep 5
      rm -rf "${dest}"
    done
    [[ "${clone_ok}" -eq 1 ]] || write_failed "git clone failed for ${repo} after 3 attempts"
  fi
  ( cd "${dest}" && npm install --silent && (npm run build --silent 2>/dev/null || true) )

  # systemd unit + env file
  env_file="/etc/soc-mcp/${name}.env"
  mkdir -p /etc/soc-mcp
  if [[ ! -f "${env_file}" ]]; then
    {
      echo "# Populated by integrate.sh after peer components come up."
      echo "PORT=${port}"
      echo "MCP_BEARER_TOKEN=${token}"
      echo "MCP_TRANSPORT=sse"
      # placeholders for the per-server env keys
      IFS=',' read -r -a keys <<< "${env_keys}"
      for k in "${keys[@]}"; do
        echo "${k}="
      done
    } > "${env_file}"
    chmod 600 "${env_file}"
  fi

  unit="/etc/systemd/system/soc-mcp-${name}.service"
  cat > "${unit}" <<UEOF
[Unit]
Description=SOC MCP server: ${name}
After=network.target

[Service]
Type=simple
EnvironmentFile=${env_file}
WorkingDirectory=${dest}
ExecStart=/usr/bin/node dist/index.js --transport sse --port \${PORT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UEOF

  systemctl daemon-reload
  systemctl enable --now "soc-mcp-${name}.service" >/dev/null 2>&1 || true

  ENDPOINTS_JSON="$(jq --arg n "${name}" --arg url "http://${IP}:${port}/sse" --arg tok "${token}" \
    '. + [{name:$n, url:$url, token:$tok}]' <<< "${ENDPOINTS_JSON}")"
done

jq -n \
  --arg ip "${IP}" \
  --argjson eps "${ENDPOINTS_JSON}" \
  '{
    component: "mcp",
    status: "deployed",
    host_ip: $ip,
    mcp_endpoints: $eps,
    services: ($eps | map("soc-mcp-" + .name))
  }' > "${STATE_FILE}"

log "deployed ${#SERVERS[@]} MCP servers"
trap - ERR
