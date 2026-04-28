#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# SOC Stack - MISP Post-Boot Setup
#
# Run AFTER docker compose up -d. Automates:
#   1. Wait for MISP to be healthy
#   2. Change default admin password
#   3. Generate API key
#   4. Save credentials
#
# Usage:
#   ./setup.sh
#   ./setup.sh --password "CustomPass123!"
# ------------------------------------------------------------------------------

set -euo pipefail

MISP_URL="https://localhost"
MISP_ADMIN_EMAIL="${MISP_ADMIN_EMAIL:-admin@misp.local}"
MISP_ADMIN_PASSPHRASE="${MISP_ADMIN_PASSPHRASE:-changeme}"
DEFAULT_PASSWORD="admin"
OUTPUT_FILE="./api-keys.txt"
MAX_WAIT=180  # MISP takes a while to boot

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

while [[ $# -gt 0 ]]; do
    case "$1" in
        --password) MISP_ADMIN_PASSPHRASE="$2"; shift 2 ;;
        --output)   OUTPUT_FILE="$2"; shift 2 ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
done

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[+]${NC} $1"; }
fail() { echo -e "${RED}[-]${NC} $1"; }
info() { echo -e "${YELLOW}[*]${NC} $1"; }

# ── Wait for MISP ────────────────────────────────────────────────────────────
info "Waiting for MISP to start (this can take 2-3 minutes)..."
elapsed=0
while ! curl -sfk "${MISP_URL}/users/login" >/dev/null 2>&1; do
    sleep 5
    elapsed=$((elapsed + 5))
    if [[ $elapsed -ge $MAX_WAIT ]]; then
        fail "MISP not responding after ${MAX_WAIT}s"
        exit 1
    fi
done
ok "MISP is up (${elapsed}s)"

# ── Login with default creds ─────────────────────────────────────────────────
info "Logging into MISP..."
LOGIN_RESPONSE=$(curl -sk -D - -X POST "${MISP_URL}/users/login" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -H 'Accept: application/json' \
    -d "data[User][email]=${MISP_ADMIN_EMAIL}&data[User][password]=${DEFAULT_PASSWORD}" 2>&1)

# Try to extract API key directly from admin user
info "Fetching admin user info..."
MISP_API_KEY=$(curl -sk "${MISP_URL}/users/view/me.json" \
    -H "Authorization: ${DEFAULT_PASSWORD}" \
    -H 'Accept: application/json' 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('User',{}).get('authkey',''))" 2>/dev/null || echo "")

if [[ -z "$MISP_API_KEY" ]]; then
    # MISP may need the cake CLI for authkey generation
    info "Generating API key via cake CLI..."
    MISP_API_KEY=$(docker compose exec -T misp-core bash -c \
        "cd /var/www/MISP/app && php cake user change_authkey ${MISP_ADMIN_EMAIL}" 2>/dev/null | \
        grep -oP '[a-zA-Z0-9]{40}' | head -1 || echo "")
fi

if [[ -n "$MISP_API_KEY" ]]; then
    ok "API key: ${MISP_API_KEY}"
else
    info "Could not auto-generate API key. Generate manually:"
    info "  docker compose exec misp-core bash -c 'cd /var/www/MISP/app && php cake user change_authkey ${MISP_ADMIN_EMAIL}'"
    MISP_API_KEY="GENERATE_MANUALLY"
fi

# ── Change password ──────────────────────────────────────────────────────────
if [[ "$MISP_ADMIN_PASSPHRASE" != "$DEFAULT_PASSWORD" ]]; then
    info "Changing admin password..."
    if [[ -n "$MISP_API_KEY" && "$MISP_API_KEY" != "GENERATE_MANUALLY" ]]; then
        curl -sk -X POST "${MISP_URL}/users/edit/1" \
            -H "Authorization: ${MISP_API_KEY}" \
            -H 'Content-Type: application/json' \
            -H 'Accept: application/json' \
            -d "{\"password\":\"${MISP_ADMIN_PASSPHRASE}\",\"confirm_password\":\"${MISP_ADMIN_PASSPHRASE}\"}" \
            >/dev/null 2>&1
        ok "Password changed"
    else
        info "Skipping password change (no API key). Change via web UI."
    fi
fi

# ── Save credentials ─────────────────────────────────────────────────────────
cat > "$OUTPUT_FILE" <<EOF
# SOC Stack: MISP Credentials
# Generated: $(date)
# VM: $(hostname -I 2>/dev/null | awk '{print $1}' || echo 'unknown')

## MISP (port 443)
URL:      ${MISP_URL}
User:     ${MISP_ADMIN_EMAIL}
Password: ${MISP_ADMIN_PASSPHRASE}
API Key:  ${MISP_API_KEY}
EOF

chmod 600 "$OUTPUT_FILE"

echo ""
echo "============================================"
echo "  MISP Setup Complete!"
echo "============================================"
echo ""
echo "  URL:      ${MISP_URL}"
echo "  User:     ${MISP_ADMIN_EMAIL}"
echo "  Password: ${MISP_ADMIN_PASSPHRASE}"
echo "  API Key:  ${MISP_API_KEY}"
echo ""
echo "  Credentials saved to: ${OUTPUT_FILE}"
echo ""
