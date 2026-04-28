#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# SOC Stack - TheHive 5.4 + Cortex 3.1.8 Post-Boot Setup
#
# Run this AFTER docker compose up -d. Automates:
#   1. Wait for services to be healthy
#   2. TheHive: login, change password, generate API key
#   3. Cortex: migrate DB, create superadmin, CSRF dance, create org + keys
#   4. Wire TheHive -> Cortex integration
#   5. Save all credentials to api-keys.txt
#
# Usage:
#   ./setup.sh                          # uses .env defaults
#   ./setup.sh --thehive-pass "X" --cortex-pass "Y" --org "MyOrg"
# ------------------------------------------------------------------------------

set -euo pipefail

# ── Defaults (override via .env/config.env or flags) ─────────────────────────
THEHIVE_URL="http://localhost:9000"
CORTEX_URL="http://localhost:9001"
THEHIVE_ADMIN_PASSWORD="${THEHIVE_ADMIN_PASSWORD:-changeme}"
CORTEX_ADMIN_PASSWORD="${CORTEX_ADMIN_PASSWORD:-changeme}"
CORTEX_ORG_NAME="${CORTEX_ORG_NAME:-Neas}"
THEHIVE_SECRET="${THEHIVE_SECRET:-soc-stack-change-me}"
OUTPUT_FILE="./api-keys.txt"
MAX_WAIT=120  # seconds

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load Compose-compatible .env first. config.env remains supported for older
# checkouts, but Docker Compose only auto-loads .env for interpolation.
ENV_FILE=""
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    ENV_FILE="${SCRIPT_DIR}/.env"
elif [[ -f "${SCRIPT_DIR}/config.env" ]]; then
    ENV_FILE="${SCRIPT_DIR}/config.env"
fi

if [[ -n "$ENV_FILE" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
fi

# ── Parse flags ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --thehive-pass) THEHIVE_ADMIN_PASSWORD="$2"; shift 2 ;;
        --cortex-pass)  CORTEX_ADMIN_PASSWORD="$2"; shift 2 ;;
        --org)          CORTEX_ORG_NAME="$2"; shift 2 ;;
        --output)       OUTPUT_FILE="$2"; shift 2 ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[+]${NC} $1"; }
fail() { echo -e "${RED}[-]${NC} $1"; }
info() { echo -e "${YELLOW}[*]${NC} $1"; }

wait_for_service() {
    local name="$1" url="$2" elapsed=0
    info "Waiting for ${name} at ${url}..."
    while ! curl -sf "${url}" >/dev/null 2>&1; do
        sleep 3
        elapsed=$((elapsed + 3))
        if [[ $elapsed -ge $MAX_WAIT ]]; then
            fail "${name} not responding after ${MAX_WAIT}s"
            exit 1
        fi
    done
    ok "${name} is up (${elapsed}s)"
}

# ── Step 1: Wait for services ────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  SOC Stack: TheHive + Cortex Setup"
echo "============================================"
echo ""

wait_for_service "Elasticsearch" "http://localhost:9200/_cluster/health"
wait_for_service "Cortex" "${CORTEX_URL}/api/status"

# TheHive takes longer (waits 30s for Cassandra internally)
info "Waiting for TheHive (may take 30-60s)..."
THEHIVE_WAIT=0
while ! curl -sf "${THEHIVE_URL}/api/v1/status/public" >/dev/null 2>&1; do
    sleep 5
    THEHIVE_WAIT=$((THEHIVE_WAIT + 5))
    if [[ $THEHIVE_WAIT -ge 120 ]]; then
        fail "TheHive not responding after 120s"
        exit 1
    fi
done
ok "TheHive is up (${THEHIVE_WAIT}s)"

# ── Step 2: TheHive admin setup ──────────────────────────────────────────────
info "Logging into TheHive with default credentials..."

THEHIVE_SESSION=$(curl -s -D - -X POST "${THEHIVE_URL}/api/v1/login" \
    -H 'Content-Type: application/json' \
    -d '{"user":"admin@thehive.local","password":"secret"}' 2>&1 | \
    grep -i 'set-cookie' | grep -oP 'THEHIVE-SESSION=\K[^;]+' | head -1)

if [[ -z "$THEHIVE_SESSION" ]]; then
    fail "Could not login to TheHive (password may already be changed)"
    info "If you already ran setup, check api-keys.txt for credentials."
    # Try with the target password
    THEHIVE_SESSION=$(curl -s -D - -X POST "${THEHIVE_URL}/api/v1/login" \
        -H 'Content-Type: application/json' \
        -d "{\"user\":\"admin@thehive.local\",\"password\":\"${THEHIVE_ADMIN_PASSWORD}\"}" 2>&1 | \
        grep -i 'set-cookie' | grep -oP 'THEHIVE-SESSION=\K[^;]+' | head -1)
    if [[ -n "$THEHIVE_SESSION" ]]; then
        ok "Logged in with target password (already changed)"
    else
        fail "Cannot login to TheHive. Aborting."
        exit 1
    fi
else
    ok "TheHive login successful"

    # Change password (use printf to handle special chars in passwords)
    # IMPORTANT: Must use /password/change endpoint, NOT PATCH /user
    info "Changing TheHive admin password..."
    CHANGE_RESULT=$(printf '{"currentPassword":"secret","password":"%s"}' "$THEHIVE_ADMIN_PASSWORD" | \
        curl -s -w '%{http_code}' -o /dev/null -X POST \
        "${THEHIVE_URL}/api/v1/user/admin@thehive.local/password/change" \
        -H "Cookie: THEHIVE-SESSION=${THEHIVE_SESSION}" \
        -H 'Content-Type: application/json' -d @-)

    if [[ "$CHANGE_RESULT" == "204" || "$CHANGE_RESULT" == "200" ]]; then
        ok "Password changed"
    else
        fail "Password change returned HTTP ${CHANGE_RESULT}"
    fi

    # Re-login with new password
    THEHIVE_SESSION=$(curl -s -D - -X POST "${THEHIVE_URL}/api/v1/login" \
        -H 'Content-Type: application/json' \
        -d "{\"user\":\"admin@thehive.local\",\"password\":\"${THEHIVE_ADMIN_PASSWORD}\"}" 2>&1 | \
        grep -i 'set-cookie' | grep -oP 'THEHIVE-SESSION=\K[^;]+' | head -1)
fi

# Generate TheHive API key
info "Generating TheHive API key..."
THEHIVE_API_KEY=$(curl -s -X POST \
    "${THEHIVE_URL}/api/v1/user/admin@thehive.local/key/renew" \
    -H "Cookie: THEHIVE-SESSION=${THEHIVE_SESSION}")

if [[ -n "$THEHIVE_API_KEY" && "$THEHIVE_API_KEY" != *"error"* ]]; then
    ok "TheHive API key: ${THEHIVE_API_KEY}"
else
    fail "Could not generate TheHive API key"
    THEHIVE_API_KEY="FAILED"
fi

# ── Step 3: Cortex setup ─────────────────────────────────────────────────────
info "Running Cortex DB migration..."
curl -s -X POST "${CORTEX_URL}/api/maintenance/migrate" \
    -H 'Content-Type: application/json' >/dev/null
ok "Migration complete"

# Create superadmin (only works when zero users exist)
info "Creating Cortex superadmin..."
CORTEX_CREATE=$(printf '{"login":"admin","name":"Admin","password":"%s","roles":["superadmin"]}' \
    "$CORTEX_ADMIN_PASSWORD" | \
    curl -s -w '\n%{http_code}' -X POST "${CORTEX_URL}/api/user" \
    -H 'Content-Type: application/json' -d @-)

CORTEX_CREATE_CODE=$(echo "$CORTEX_CREATE" | tail -1)
if [[ "$CORTEX_CREATE_CODE" == "201" || "$CORTEX_CREATE_CODE" == "200" ]]; then
    ok "Superadmin created"
elif [[ "$CORTEX_CREATE_CODE" == "400" || "$CORTEX_CREATE_CODE" == "409" ]]; then
    info "Superadmin already exists (already set up)"
else
    fail "Superadmin creation returned HTTP ${CORTEX_CREATE_CODE}"
fi

# Login to Cortex
info "Logging into Cortex..."
CORTEX_LOGIN_RESPONSE=$(printf '{"user":"admin","password":"%s"}' "$CORTEX_ADMIN_PASSWORD" | \
    curl -s -D - -X POST "${CORTEX_URL}/api/login" \
    -H 'Content-Type: application/json' -d @- 2>&1)

CORTEX_SESSION=$(echo "$CORTEX_LOGIN_RESPONSE" | \
    grep -i 'set-cookie' | grep -oP 'CORTEX_SESSION=\K[^;]+' | head -1)

if [[ -z "$CORTEX_SESSION" ]]; then
    fail "Could not login to Cortex"
    exit 1
fi
ok "Cortex login successful"

# ── CSRF Dance ────────────────────────────────────────────────────────────────
# Cortex uses Elastic4Play CSRF protection. All POST/PUT/PATCH/DELETE with
# session cookies require the CSRF token. Get it from any GET response.
#
# Cookie name:  CORTEX-XSRF-TOKEN
# Header name:  X-CORTEX-XSRF-TOKEN
# Both must be sent on every mutating request.
info "Acquiring Cortex CSRF token..."

CSRF_RESPONSE=$(curl -s -D - "${CORTEX_URL}/api/user/admin" \
    -H "Cookie: CORTEX_SESSION=${CORTEX_SESSION}" 2>&1)

CSRF_TOKEN=$(echo "$CSRF_RESPONSE" | \
    grep -i 'CORTEX-XSRF-TOKEN' | sed 's/.*CORTEX-XSRF-TOKEN=//;s/;.*//' | tr -d '\r')

if [[ -z "$CSRF_TOKEN" ]]; then
    fail "Could not get CSRF token"
    exit 1
fi
ok "CSRF token acquired"

# Helper for Cortex authenticated requests (handles CSRF automatically)
cortex_post() {
    local endpoint="$1"
    shift
    curl -s "$@" -X POST "${CORTEX_URL}${endpoint}" \
        -H "Cookie: CORTEX_SESSION=${CORTEX_SESSION}; CORTEX-XSRF-TOKEN=${CSRF_TOKEN}" \
        -H "X-CORTEX-XSRF-TOKEN: ${CSRF_TOKEN}" \
        -H 'Content-Type: application/json'
}

# Create organization
info "Creating Cortex organization '${CORTEX_ORG_NAME}'..."
ORG_RESULT=$(printf '{"name":"%s","description":"%s organization","status":"Active"}' \
    "$CORTEX_ORG_NAME" "$CORTEX_ORG_NAME" | \
    cortex_post "/api/organization" -d @-)
ok "Organization created"

# Create org admin user
info "Creating Cortex org admin user..."
printf '{"name":"%s Admin","roles":["read","analyze","orgadmin"],"organization":"%s","login":"%s-admin"}' \
    "$CORTEX_ORG_NAME" "$CORTEX_ORG_NAME" "$(echo "$CORTEX_ORG_NAME" | tr '[:upper:]' '[:lower:]')" | \
    cortex_post "/api/user" -d @- >/dev/null
ok "Org admin created"

# Generate API keys
info "Generating Cortex API keys..."
CORTEX_ADMIN_KEY=$(cortex_post "/api/user/admin/key/renew")
ok "Cortex superadmin key: ${CORTEX_ADMIN_KEY}"

CORTEX_ORG_KEY=$(cortex_post "/api/user/$(echo "$CORTEX_ORG_NAME" | tr '[:upper:]' '[:lower:]')-admin/key/renew")
ok "Cortex org admin key: ${CORTEX_ORG_KEY}"

# ── Step 4: Wire TheHive -> Cortex ───────────────────────────────────────────
info "Wiring TheHive -> Cortex integration..."

# Update docker-compose command to include Cortex connection
# Use the org admin key (least privilege)
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"

if grep -q "cortex-hostnames" "$COMPOSE_FILE" 2>/dev/null; then
    info "Cortex integration already in docker-compose.yml (skipping)"
else
    # Add Cortex args to TheHive command block
    sed -i '/^      - "elasticsearch"$/a\      - "--cortex-hostnames"\n      - "cortex"\n      - "--cortex-keys"\n      - "'"${CORTEX_ORG_KEY}"'"' \
        "$COMPOSE_FILE"
    ok "Updated docker-compose.yml with Cortex connection"

    info "Restarting TheHive to pick up Cortex integration..."
    cd "$SCRIPT_DIR"
    docker compose up -d thehive >/dev/null 2>&1
    sleep 15
    ok "TheHive restarted"
fi

# ── Step 5: Save credentials ─────────────────────────────────────────────────
cat > "$OUTPUT_FILE" <<EOF
# SOC Stack: TheHive + Cortex Credentials
# Generated: $(date)
# VM: $(hostname -I 2>/dev/null | awk '{print $1}' || echo 'unknown')

## TheHive (port 9000)
User:     admin@thehive.local
Password: ${THEHIVE_ADMIN_PASSWORD}
API Key:  ${THEHIVE_API_KEY}

## Cortex (port 9001)
Superadmin:     admin / ${CORTEX_ADMIN_PASSWORD}
Superadmin Key: ${CORTEX_ADMIN_KEY}
Org Admin:      $(echo "$CORTEX_ORG_NAME" | tr '[:upper:]' '[:lower:]')-admin (no password, API key only)
Org Admin Key:  ${CORTEX_ORG_KEY}
Organization:   ${CORTEX_ORG_NAME}

## Integration
TheHive -> Cortex: connected via org admin key
EOF

chmod 600 "$OUTPUT_FILE"

echo ""
echo "============================================"
echo "  Setup Complete!"
echo "============================================"
echo ""
echo "  TheHive: ${THEHIVE_URL} (admin@thehive.local / ${THEHIVE_ADMIN_PASSWORD})"
echo "  Cortex:  ${CORTEX_URL} (admin / ${CORTEX_ADMIN_PASSWORD})"
echo ""
echo "  Credentials saved to: ${OUTPUT_FILE}"
echo ""
echo "  Verify:"
echo "    curl -s ${THEHIVE_URL}/api/v1/user/current -H 'Authorization: Bearer ${THEHIVE_API_KEY}'"
echo "    curl -s ${CORTEX_URL}/api/status"
echo ""
