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
chmod 700 "${SECRETS_DIR}" 2>/dev/null || true

log()  { printf '[thc-deploy] %s\n' "$*"; }

get_or_create_secret() {
  local name="$1"
  local file="${SECRETS_DIR}/${name}.txt"
  if [[ -f "${file}" ]]; then
    cat "${file}"
    return 0
  fi
  local value
  value="$(openssl rand -hex 32)"
  printf '%s' "${value}" > "${file}"
  chmod 600 "${file}"
  printf '%s' "${value}"
}

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
services_running="$(docker compose -f "${STACK_DIR}/docker-compose.yml" ps \
                     --filter "status=running" --services 2>/dev/null || true)"
if grep -qx "thehive" <<< "${services_running}" \
   && grep -qx "cortex" <<< "${services_running}"; then
  log "stack already running, refreshing state"
  IP="$(hostname -I | awk '{print $1}')"

  THEHIVE_PASS="$(cat "${SECRETS_DIR}/thehive-admin.txt" 2>/dev/null || echo "")"
  THEHIVE_KEY="$(cat "${SECRETS_DIR}/thehive-apikey.txt" 2>/dev/null || echo "")"
  CORTEX_PASS="$(cat "${SECRETS_DIR}/cortex-admin.txt" 2>/dev/null || echo "")"
  CORTEX_KEY="$(cat "${SECRETS_DIR}/cortex-apikey.txt" 2>/dev/null || echo "")"

  # Never report deployed with missing credentials: a previous run that died
  # mid-rotation would otherwise look healthy while nothing can authenticate.
  if [[ -z "${THEHIVE_PASS}" || -z "${THEHIVE_KEY}" || -z "${CORTEX_PASS}" || -z "${CORTEX_KEY}" ]]; then
    write_failed "stack is running but stored credentials are incomplete under ${SECRETS_DIR}; run destroy.sh for thehive-cortex, then redeploy"
  fi

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
THEHIVE_SECRET="$(get_or_create_secret thehive-secret)"
cat > "${STACK_DIR}/docker-compose.yml" <<COMPOSE_EOF
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
      - TH_SECRET=${THEHIVE_SECRET}
    command:
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

log "waiting for Cassandra to accept CQL connections on :9042 (up to 900s)"
cassandra_ok=0
elapsed=0
while (( elapsed < 900 )); do
  # Probe Cassandra native transport via a no-data bash /dev/tcp open.
  # `cat` hangs waiting for the server to send data (Cassandra never sends first),
  # so use `:` (bash no-op) which exits immediately after the TCP handshake.
  # Run inside the cassandra container so Docker DNS resolution is not needed.
  if timeout 5 docker compose -f "${STACK_DIR}/docker-compose.yml" \
       exec -T cassandra bash -c ': < /dev/tcp/127.0.0.1/9042' >/dev/null 2>&1; then
    cassandra_ok=1
    log "Cassandra accepting CQL on :9042 after ${elapsed}s"
    break
  fi
  sleep 10
  elapsed=$((elapsed + 10))
  (( elapsed % 60 == 0 )) && log "  ... cassandra not ready, ${elapsed}s elapsed"
done

if (( cassandra_ok != 1 )); then
  write_failed "Cassandra did not accept CQL within 900s"
fi

log "waiting for TheHive on :9000 (up to 1200s)"
wait_http "http://localhost:9000/api/status" 1200 "TheHive" || write_failed "TheHive did not become ready within 1200s"
log "waiting for Cortex on :9001 (up to 900s)"
wait_http "http://localhost:9001/api/status" 900 "Cortex" || write_failed "Cortex did not become ready within 900s"

# --- Cortex first-run wizard ---
# Cortex 3.1.8 auto-initialises itself on first boot: it creates the default
# admin user in ES with a random hashed password before the wizard can run.
# The approach here is to reset that auto-created admin password to a known
# value via the ES API (security is disabled), then proceed normally.
#
# Cortex password hash format: <ascii-salt>,<sha256(salt+password)>
# CSRF cookie: CORTEX-XSRF-TOKEN  /  required header: X-CORTEX-XSRF-TOKEN
log "patching Cortex admin password via Elasticsearch (auto-init workaround)"
CORTEX_ADMIN_PASS="$(openssl rand -hex 12)"
CORTEX_PW_SALT="s3-$(openssl rand -hex 6)"
CORTEX_PW_HASH="$(printf '%s%s' "${CORTEX_PW_SALT}" "${CORTEX_ADMIN_PASS}" | sha256sum | cut -d' ' -f1)"
CORTEX_PW_STORED="${CORTEX_PW_SALT},${CORTEX_PW_HASH}"

# Wait until the cortex_6 ES index exists (auto-init runs shortly after HTTP ready)
# Auto-init can take up to 3 minutes; poll every 5s for up to 180s.
log "waiting for Cortex auto-init to populate cortex_6/admin in Elasticsearch (up to 180s)"
es_patch_ok=0
es_elapsed=0
while (( es_elapsed < 180 )); do
  if docker compose -f "${STACK_DIR}/docker-compose.yml" exec -T elasticsearch \
       curl -sf "http://localhost:9200/cortex_6/_doc/admin?routing=admin" >/dev/null 2>&1; then
    es_patch_ok=1
    log "cortex_6/admin appeared after ${es_elapsed}s"
    break
  fi
  sleep 5
  es_elapsed=$((es_elapsed + 5))
  (( es_elapsed % 30 == 0 )) && log "  ... cortex_6/admin not yet, ${es_elapsed}s elapsed"
done
(( es_patch_ok )) || write_failed "cortex_6/admin ES doc did not appear within 180s"

docker compose -f "${STACK_DIR}/docker-compose.yml" exec -T elasticsearch \
  curl -sf -X POST \
    "http://localhost:9200/cortex_6/_update/admin?routing=admin" \
    -H "Content-Type: application/json" \
    -d "{\"doc\":{\"password\":\"${CORTEX_PW_STORED}\",\"updatedBy\":\"wizard\",\"updatedAt\":$(date +%s)000}}" \
  >/dev/null || write_failed "failed to patch Cortex admin password in Elasticsearch"
log "Cortex admin password patched"

log "running Cortex first-run wizard"
# Login, then fetch the root page to obtain the CORTEX-XSRF-TOKEN cookie.
# Use X-CORTEX-XSRF-TOKEN header for subsequent mutating requests (per reference.conf).
CJAR="$(mktemp)"
curl -sf -c "${CJAR}" -H "Content-Type: application/json" \
  -X POST "http://localhost:9001/api/login" \
  -d "{\"user\":\"admin\",\"password\":\"${CORTEX_ADMIN_PASS}\"}" >/dev/null \
  || write_failed "Cortex admin login failed after password patch"
curl -sf -c "${CJAR}" -b "${CJAR}" "http://localhost:9001/" >/dev/null 2>&1
CSRF="$(awk '/CORTEX-XSRF-TOKEN/ {print $7}' "${CJAR}" | head -1)"

# Create S3-CORTEX organization
curl -sf -b "${CJAR}" -c "${CJAR}" -H "X-CORTEX-XSRF-TOKEN: ${CSRF}" \
  -H "Content-Type: application/json" \
  -X POST "http://localhost:9001/api/organization" \
  -d '{"name":"S3-CORTEX","description":"S3 SOC Stack Cortex org","status":"Active"}' >/dev/null \
  || write_failed "failed to create S3-CORTEX organisation in Cortex"

# Create "thehive" user in S3-CORTEX (for the TheHive-to-Cortex link)
curl -sf -b "${CJAR}" -c "${CJAR}" -H "X-CORTEX-XSRF-TOKEN: ${CSRF}" \
  -H "Content-Type: application/json" \
  -X POST "http://localhost:9001/api/user" \
  -d '{"login":"thehive","name":"thehive","organization":"S3-CORTEX","roles":["read","analyze"]}' >/dev/null \
  || write_failed "failed to create thehive user in Cortex"

CORTEX_API_KEY="$(curl -sf -b "${CJAR}" \
  -H "X-CORTEX-XSRF-TOKEN: ${CSRF}" \
  -H "Content-Type: application/json" \
  -X POST "http://localhost:9001/api/user/thehive/key/renew" \
  -d '{}' | tr -d '"')"
[ -n "${CORTEX_API_KEY}" ] || write_failed "failed to mint Cortex API key for thehive user"

# --- TheHive admin password rotation + API key ---
log "rotating TheHive admin password + minting API key"
THEHIVE_DEFAULT_PASS="secret"
# Persisted before rotation so a crash mid-rotation is recoverable on re-run.
THEHIVE_ADMIN_PASS="$(get_or_create_secret thehive-admin)"

thehive_login() {
  local pass="$1"
  local jar="$2"
  curl -sf -c "${jar}" -H "Content-Type: application/json" \
    -X POST "http://localhost:9000/api/v1/session" \
    -d "{\"login\":\"admin@thehive.local\",\"password\":\"${pass}\"}" >/dev/null 2>&1
}

TCJAR="$(mktemp)"
if thehive_login "${THEHIVE_ADMIN_PASS}" "${TCJAR}"; then
  log "TheHive admin password already rotated (previous run)"
elif thehive_login "${THEHIVE_DEFAULT_PASS}" "${TCJAR}"; then
  # Change password (uses /password/change endpoint, NOT /user)
  curl -sf -b "${TCJAR}" -H "Content-Type: application/json" \
    -X POST "http://localhost:9000/api/v1/user/admin%40thehive.local/password/change" \
    -d "{\"currentPassword\":\"${THEHIVE_DEFAULT_PASS}\",\"password\":\"${THEHIVE_ADMIN_PASS}\"}" >/dev/null \
    || write_failed "TheHive admin password rotation request failed"

  # Verify: the new password must log in. The component is not deployed
  # until the upstream default credential is confirmed dead.
  TCJAR="$(mktemp)"
  thehive_login "${THEHIVE_ADMIN_PASS}" "${TCJAR}" \
    || write_failed "TheHive password rotation could not be verified (new password rejected)"
  if thehive_login "${THEHIVE_DEFAULT_PASS}" "$(mktemp)"; then
    write_failed "TheHive default password still accepted after rotation"
  fi
  log "TheHive admin password rotated and verified"
else
  write_failed "TheHive admin login failed with both stored and default credentials"
fi

# Mint API key
THEHIVE_API_KEY="$(curl -sf -b "${TCJAR}" -H "Content-Type: application/json" \
  -X POST "http://localhost:9000/api/v1/user/admin%40thehive.local/key/renew" | tr -d '"\n')"
[[ -n "${THEHIVE_API_KEY}" ]] || write_failed "failed to mint TheHive API key"

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
