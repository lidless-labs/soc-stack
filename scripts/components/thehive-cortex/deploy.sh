#!/usr/bin/env bash
# scripts/components/thehive-cortex/deploy.sh
# Runs INSIDE the thehive-cortex LXC. Idempotent. Deploys the Docker Compose
# stack and configures admin accounts + API keys.
#
# Required env (set by orchestrator):
#   SOC_STATE_DIR        - local-to-LXC dir; orchestrator pulls it back via pct pull
#   SOC_COMPONENT        - "thehive-cortex"
#   SOC_PRESET           - informational
#   SOC_NON_INTERACTIVE  - "1"
#
# Result JSON keys (written to ${SOC_STATE_DIR}/state/thehive-cortex.json on success):
#   status, thehive.{url,api_url,admin_user,admin_password,api_key},
#   cortex.{url,admin_user,admin_password,api_key,org}

set -euo pipefail

: "${SOC_STATE_DIR:?SOC_STATE_DIR must be set}"
: "${SOC_COMPONENT:=thehive-cortex}"

STATE_FILE="${SOC_STATE_DIR}/state/${SOC_COMPONENT}.json"
SECRETS_DIR="${SOC_STATE_DIR}/secrets"
STACK_DIR="/opt/soc-stack/thehive-cortex"
mkdir -p "${SOC_STATE_DIR}/state" "${SECRETS_DIR}" "${STACK_DIR}"

log()  { printf '[thc-deploy] %s\n' "$*"; }

write_failed() {
  local err="$1"
  jq -n --arg err "${err}" '{
    component: "thehive-cortex",
    status: "failed",
    error: $err
  }' > "${STATE_FILE}"
  log "FAILED: ${err}"
  exit 1
}
trap 'write_failed "deploy.sh aborted on line $LINENO"' ERR

# --- Idempotency: already running and healthy? ---
if docker compose -f "${STACK_DIR}/docker-compose.yml" ps 2>/dev/null | grep -q "thehive.*running" \
   && docker compose -f "${STACK_DIR}/docker-compose.yml" ps 2>/dev/null | grep -q "cortex.*running"; then
  log "stack already running, refreshing state"
  IP="$(hostname -I | awk '{print $1}')"

  THEHIVE_PASS="$(cat "${SECRETS_DIR}/thehive-admin.txt" 2>/dev/null || echo "")"
  THEHIVE_KEY="$(cat "${SECRETS_DIR}/thehive-apikey.txt" 2>/dev/null || echo "")"
  CORTEX_PASS="$(cat "${SECRETS_DIR}/cortex-admin.txt" 2>/dev/null || echo "")"
  CORTEX_KEY="$(cat "${SECRETS_DIR}/cortex-apikey.txt" 2>/dev/null || echo "")"

  jq -n \
    --arg ip "${IP}" \
    --arg thp "${THEHIVE_PASS}" --arg thk "${THEHIVE_KEY}" \
    --arg cxp "${CORTEX_PASS}"  --arg cxk "${CORTEX_KEY}" \
    '{
      component: "thehive-cortex",
      status: "deployed",
      thehive: {
        url: ("http://" + $ip + ":9000"),
        api_url: ("http://" + $ip + ":9000/api"),
        admin_user: "admin@thehive.local",
        admin_password: $thp,
        api_key: $thk
      },
      cortex: {
        url: ("http://" + $ip + ":9001"),
        admin_user: "admin",
        admin_password: $cxp,
        api_key: $cxk,
        org: "S3-CORTEX"
      },
      services: ["cassandra","elasticsearch","thehive","cortex"]
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
cat > "${STACK_DIR}/docker-compose.yml" <<'COMPOSE_EOF'
services:
  cassandra:
    image: cassandra:4.1
    container_name: cassandra
    environment:
      - CASSANDRA_CLUSTER_NAME=thp
      - JVM_OPTS=-Xms512M -Xmx512M
    volumes:
      - cassandra-data:/var/lib/cassandra/data
    restart: unless-stopped

  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:7.17.20
    container_name: elasticsearch
    environment:
      - discovery.type=single-node
      - xpack.security.enabled=false
      - "ES_JAVA_OPTS=-Xms512m -Xmx512m"
      - thread_pool.search.queue_size=100000
      - thread_pool.write.queue_size=10000
      - bootstrap.memory_lock=false
      - bootstrap.system_call_filter=false
    ulimits:
      nofile: { soft: 65536, hard: 65536 }
    volumes:
      - es-data:/usr/share/elasticsearch/data
    restart: unless-stopped

  thehive:
    image: strangebee/thehive:5.4
    container_name: thehive
    depends_on: [cassandra, elasticsearch]
    ports: ["9000:9000"]
    environment:
      - JVM_OPTS=-Xms1024M -Xmx1024M
    command:
      - --no-config-secret
      - --secret
      - "${THEHIVE_SECRET:-thp-secret-change-me}"
      - --cql-hostnames
      - cassandra
      - --index-backend
      - elasticsearch
      - --es-hostnames
      - elasticsearch
    restart: unless-stopped

  cortex:
    image: thehiveproject/cortex:3.1.8
    container_name: cortex
    depends_on: [elasticsearch]
    ports: ["9001:9001"]
    environment:
      - JVM_OPTS=-Xms512M -Xmx512M
      - job_directory=/tmp/cortex-jobs
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    restart: unless-stopped

volumes:
  cassandra-data:
  es-data:
COMPOSE_EOF

log "starting compose stack (may take 5-10 minutes for Cassandra + ES warmup)"
docker compose -f "${STACK_DIR}/docker-compose.yml" up -d

wait_http() {
  local url="$1"
  local timeout="${2:-180}"
  local label="${3:-service}"
  local elapsed=0
  while (( elapsed < timeout )); do
    if curl -sf -o /dev/null --max-time 5 "${url}"; then return 0; fi
    sleep 10
    elapsed=$((elapsed + 10))
    (( elapsed % 60 == 0 )) && log "  ... ${label} ${elapsed}s, still waiting"
  done
  return 1
}

log "waiting for Cassandra cluster to become operational (up to 600s)"
cassandra_ok=0
elapsed=0
while (( elapsed < 600 )); do
  # nodetool exits 0 only when at least one node reports UN (Up Normal)
  if docker compose -f "${STACK_DIR}/docker-compose.yml" exec -T cassandra nodetool status 2>/dev/null | grep -qE '^UN '; then
    cassandra_ok=1
    log "Cassandra cluster up after ${elapsed}s"
    break
  fi
  sleep 10
  elapsed=$((elapsed + 10))
  (( elapsed % 60 == 0 )) && log "  ... cassandra not ready, ${elapsed}s elapsed"
done

if (( cassandra_ok != 1 )); then
  write_failed "Cassandra did not become operational within 600s"
fi

# Restart TheHive now that Cassandra is ready, so it gets a clean boot
log "restarting TheHive after Cassandra ready"
docker compose -f "${STACK_DIR}/docker-compose.yml" restart thehive
sleep 5

log "waiting for TheHive on :9000 (up to 900s)"
wait_http "http://localhost:9000/api/status" 900 "TheHive" || write_failed "TheHive did not become ready within 900s"
log "waiting for Cortex on :9001 (up to 900s)"
wait_http "http://localhost:9001/api/status" 900 "Cortex" || write_failed "Cortex did not become ready within 900s"

# --- Cortex first-run wizard ---
log "running Cortex first-run wizard"
# Cortex requires a session cookie + CSRF token dance
CJAR="$(mktemp)"
curl -sf -c "${CJAR}" "http://localhost:9001/" >/dev/null
CSRF="$(awk '/X-XSRF-TOKEN/ || /XSRF-TOKEN/ {print $7}' "${CJAR}" | head -1)"
# Migrate (initializes index)
curl -sf -b "${CJAR}" -c "${CJAR}" -H "X-XSRF-TOKEN: ${CSRF}" \
  -X POST "http://localhost:9001/api/maintenance/migrate" -d '{}' >/dev/null || true

CORTEX_ADMIN_PASS="$(openssl rand -hex 12)"
curl -sf -b "${CJAR}" -c "${CJAR}" -H "X-XSRF-TOKEN: ${CSRF}" \
  -H "Content-Type: application/json" \
  -X POST "http://localhost:9001/api/user" \
  -d "{\"login\":\"admin\",\"name\":\"admin\",\"password\":\"${CORTEX_ADMIN_PASS}\",\"roles\":[\"superAdmin\"]}" >/dev/null

# Login as admin
curl -sf -c "${CJAR}" -H "Content-Type: application/json" \
  -X POST "http://localhost:9001/api/login" \
  -d "{\"user\":\"admin\",\"password\":\"${CORTEX_ADMIN_PASS}\"}" >/dev/null
CSRF="$(awk '/X-XSRF-TOKEN/ || /XSRF-TOKEN/ {print $7}' "${CJAR}" | head -1)"

# Create S3-CORTEX organization
curl -sf -b "${CJAR}" -c "${CJAR}" -H "X-XSRF-TOKEN: ${CSRF}" \
  -H "Content-Type: application/json" \
  -X POST "http://localhost:9001/api/organization" \
  -d '{"name":"S3-CORTEX","description":"S3 SOC Stack Cortex org","status":"Active"}' >/dev/null

# Create org-admin "thehive" user (for the TheHive-to-Cortex link) and key
curl -sf -b "${CJAR}" -c "${CJAR}" -H "X-XSRF-TOKEN: ${CSRF}" \
  -H "Content-Type: application/json" \
  -X POST "http://localhost:9001/api/user" \
  -d '{"login":"thehive","name":"thehive","organization":"S3-CORTEX","roles":["read","analyze"]}' >/dev/null

CORTEX_API_KEY="$(curl -sf -b "${CJAR}" -H "X-XSRF-TOKEN: ${CSRF}" \
  -X POST "http://localhost:9001/api/user/thehive/key/renew" | tr -d '"')"

# --- TheHive admin password rotation + API key ---
log "rotating TheHive admin password + minting API key"
THEHIVE_DEFAULT_PASS="secret"
THEHIVE_ADMIN_PASS="$(openssl rand -hex 12)"

# Login with default
TCJAR="$(mktemp)"
curl -sf -c "${TCJAR}" -H "Content-Type: application/json" \
  -X POST "http://localhost:9000/api/v1/session" \
  -d "{\"login\":\"admin@thehive.local\",\"password\":\"${THEHIVE_DEFAULT_PASS}\"}" >/dev/null

# Change password (uses /password/change endpoint, NOT /user)
curl -sf -b "${TCJAR}" -H "Content-Type: application/json" \
  -X POST "http://localhost:9000/api/v1/user/admin%40thehive.local/password/change" \
  -d "{\"currentPassword\":\"${THEHIVE_DEFAULT_PASS}\",\"password\":\"${THEHIVE_ADMIN_PASS}\"}" >/dev/null

# Re-login with new password
TCJAR="$(mktemp)"
curl -sf -c "${TCJAR}" -H "Content-Type: application/json" \
  -X POST "http://localhost:9000/api/v1/session" \
  -d "{\"login\":\"admin@thehive.local\",\"password\":\"${THEHIVE_ADMIN_PASS}\"}" >/dev/null

# Mint API key
THEHIVE_API_KEY="$(curl -sf -b "${TCJAR}" -H "Content-Type: application/json" \
  -X POST "http://localhost:9000/api/v1/user/admin%40thehive.local/key/renew" | tr -d '"\n')"

# Persist secrets
printf '%s' "${THEHIVE_ADMIN_PASS}" > "${SECRETS_DIR}/thehive-admin.txt"
printf '%s' "${THEHIVE_API_KEY}"    > "${SECRETS_DIR}/thehive-apikey.txt"
printf '%s' "${CORTEX_ADMIN_PASS}"  > "${SECRETS_DIR}/cortex-admin.txt"
printf '%s' "${CORTEX_API_KEY}"     > "${SECRETS_DIR}/cortex-apikey.txt"
chmod 600 "${SECRETS_DIR}"/{thehive,cortex}-*.txt

IP="$(hostname -I | awk '{print $1}')"

jq -n \
  --arg ip "${IP}" \
  --arg thp "${THEHIVE_ADMIN_PASS}" --arg thk "${THEHIVE_API_KEY}" \
  --arg cxp "${CORTEX_ADMIN_PASS}"  --arg cxk "${CORTEX_API_KEY}" \
  '{
    component: "thehive-cortex",
    status: "deployed",
    thehive: {
      url: ("http://" + $ip + ":9000"),
      api_url: ("http://" + $ip + ":9000/api"),
      admin_user: "admin@thehive.local",
      admin_password: $thp,
      api_key: $thk
    },
    cortex: {
      url: ("http://" + $ip + ":9001"),
      admin_user: "admin",
      admin_password: $cxp,
      api_key: $cxk,
      org: "S3-CORTEX"
    },
    services: ["cassandra","elasticsearch","thehive","cortex"]
  }' > "${STATE_FILE}"

log "deploy complete: TheHive at http://${IP}:9000  Cortex at http://${IP}:9001"
trap - ERR
