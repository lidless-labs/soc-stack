#!/usr/bin/env bash
# scripts/components/misp/deploy.sh
# Runs INSIDE the misp LXC. Idempotent. Deploys the Docker Compose stack and
# rotates the admin password + generates an API key via the cake CLI.
#
# Required env (set by orchestrator):
#   SOC_STATE_DIR        - local-to-LXC dir; orchestrator pulls it back via pct pull
#   SOC_COMPONENT        - "misp"
#   SOC_PRESET           - informational
#   SOC_NON_INTERACTIVE  - "1"
#
# Result JSON keys (written to ${SOC_STATE_DIR}/state/misp.json on success):
#   component, status, url, api_url, admin_user, admin_password, api_key, services

set -euo pipefail

: "${SOC_STATE_DIR:?SOC_STATE_DIR must be set}"
: "${SOC_COMPONENT:=misp}"

STATE_FILE="${SOC_STATE_DIR}/state/${SOC_COMPONENT}.json"
SECRETS_DIR="${SOC_STATE_DIR}/secrets"
STACK_DIR="/opt/soc-stack/misp"
mkdir -p "${SOC_STATE_DIR}/state" "${SECRETS_DIR}" "${STACK_DIR}"

MISP_ADMIN_EMAIL="admin@admin.test"

log() { printf '[misp-deploy] %s\n' "$*"; }

write_failed() {
  local err="$1"
  jq -n --arg err "${err}" '{
    component: "misp",
    status: "failed",
    error: $err
  }' > "${STATE_FILE}"
  log "FAILED: ${err}"
  exit 1
}
trap 'write_failed "deploy.sh aborted on line $LINENO"' ERR

# --- Idempotency: already running and healthy? ---
if docker compose -f "${STACK_DIR}/docker-compose.yml" ps 2>/dev/null | grep -q "misp-core.*running"; then
  log "stack already running, refreshing state"
  IP="$(hostname -I | awk '{print $1}')"

  MISP_PASS="$(cat "${SECRETS_DIR}/misp-admin.txt" 2>/dev/null || echo "")"
  MISP_KEY="$(cat "${SECRETS_DIR}/misp-apikey.txt" 2>/dev/null || echo "")"

  jq -n \
    --arg ip "${IP}" \
    --arg pw "${MISP_PASS}" \
    --arg key "${MISP_KEY}" \
    --arg email "${MISP_ADMIN_EMAIL}" \
    '{
      component: "misp",
      status: "deployed",
      url: ("https://" + $ip),
      api_url: ("https://" + $ip),
      admin_user: $email,
      admin_password: $pw,
      api_key: $key,
      services: ["mariadb","redis","misp-core","misp-modules"]
    }' > "${STATE_FILE}"
  exit 0
fi

# --- Fresh install ---
export DEBIAN_FRONTEND=noninteractive

log "installing docker engine + compose"
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg jq
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
# shellcheck disable=SC1091
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

log "writing docker-compose.yml"
# CRITICAL gotcha (docs/gotchas.md): default InnoDB buffer pool is 2GB, causes
# OOM on 4GB hosts. Hardcode 512M; sufficient for standard preset (4GB RAM).
cat > "${STACK_DIR}/docker-compose.yml" <<'COMPOSE_EOF'
services:
  misp-core:
    image: ghcr.io/misp/misp-docker/misp-core:latest
    hostname: misp
    restart: unless-stopped
    ports:
      - "443:443"
      - "80:80"
    environment:
      MISP_ADMIN_EMAIL: "admin@admin.test"
      MISP_ADMIN_PASSPHRASE: "admin"
      MISP_BASEURL: "https://localhost"
    volumes:
      - misp-data:/var/www/MISP
    depends_on:
      misp-db:
        condition: service_healthy
      redis:
        condition: service_started
    healthcheck:
      test: ["CMD-SHELL", "curl -sfk https://localhost/users/login || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 120s

  misp-db:
    image: mariadb:10.11
    hostname: misp-db
    restart: unless-stopped
    environment:
      MYSQL_DATABASE: misp
      MYSQL_USER: misp
      MYSQL_PASSWORD: "misp-secret"
      MYSQL_ROOT_PASSWORD: "root-secret"
      INNODB_BUFFER_POOL_SIZE: "512M"
    volumes:
      - misp-db-data:/var/lib/mysql
    command: >
      --innodb-buffer-pool-size=512M
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 15s
      timeout: 5s
      retries: 10
      start_period: 30s

  redis:
    image: redis:7-alpine
    hostname: redis
    restart: unless-stopped

  misp-modules:
    image: ghcr.io/misp/misp-docker/misp-modules:latest
    restart: unless-stopped
    depends_on:
      - misp-core

volumes:
  misp-data:
  misp-db-data:
COMPOSE_EOF

log "starting compose stack (MISP takes 2-4 minutes to initialize)"
docker compose -f "${STACK_DIR}/docker-compose.yml" up -d

wait_http() {
  local url="$1"
  local timeout="${2:-180}"
  local elapsed=0
  while (( elapsed < timeout )); do
    # shellcheck disable=SC2166
    if curl -sk -o /dev/null --max-time 5 "${url}"; then return 0; fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  return 1
}

log "waiting for MISP on https://localhost (up to 300s)"
wait_http "https://localhost/users/heartbeat" 300 \
  || write_failed "MISP did not become ready within 300s"

# --- Generate API key via cake CLI ---
# MISP advanced authkeys are enabled by default; the REST endpoint approach is
# unreliable at first boot. The cake CLI is the authoritative method.
# (docs/gotchas.md: Advanced Authkeys section)
log "generating API key via cake CLI"
MISP_API_KEY=""
MISP_API_KEY="$(docker compose -f "${STACK_DIR}/docker-compose.yml" exec -T misp-core bash -c \
  "cd /var/www/MISP/app && php cake user change_authkey ${MISP_ADMIN_EMAIL}" 2>/dev/null \
  | grep -oP '[a-zA-Z0-9]{40}' | head -1 || true)"

if [[ -z "${MISP_API_KEY}" ]]; then
  write_failed "could not generate API key via cake CLI"
fi
log "API key obtained (${#MISP_API_KEY} chars)"

# --- Admin password rotation ---
# Use printf | curl to avoid bash history expansion on special chars.
# POST /users/edit/1 with JSON body, Authorization: <api_key> header.
MISP_ADMIN_PASS="$(LC_ALL=C tr -dc 'A-Za-z0-9_+=.-' </dev/urandom | head -c 24)"
log "rotating admin password"
printf '{"password":"%s","confirm_password":"%s"}' \
  "${MISP_ADMIN_PASS}" "${MISP_ADMIN_PASS}" \
  | curl -sk -X POST "https://localhost/users/edit/1" \
      -H "Authorization: ${MISP_API_KEY}" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      --data @- \
      -o /dev/null

# --- Persist secrets ---
printf '%s' "${MISP_ADMIN_PASS}" > "${SECRETS_DIR}/misp-admin.txt"
printf '%s' "${MISP_API_KEY}"    > "${SECRETS_DIR}/misp-apikey.txt"
chmod 600 "${SECRETS_DIR}/misp-admin.txt" "${SECRETS_DIR}/misp-apikey.txt"

IP="$(hostname -I | awk '{print $1}')"

jq -n \
  --arg ip "${IP}" \
  --arg email "${MISP_ADMIN_EMAIL}" \
  --arg pw "${MISP_ADMIN_PASS}" \
  --arg key "${MISP_API_KEY}" \
  '{
    component: "misp",
    status: "deployed",
    url: ("https://" + $ip),
    api_url: ("https://" + $ip),
    admin_user: $email,
    admin_password: $pw,
    api_key: $key,
    services: ["mariadb","redis","misp-core","misp-modules"]
  }' > "${STATE_FILE}"

log "deploy complete: MISP at https://${IP}"
trap - ERR
