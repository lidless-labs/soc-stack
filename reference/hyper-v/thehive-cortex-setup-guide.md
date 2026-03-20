# TheHive 5.4 + Cortex 3.1.8 - Full Setup Guide

## Overview
Fresh Docker Compose deployment of TheHive 5.4 and Cortex 3.1.8 on a dedicated VM (<VM_IP>), with Elasticsearch 7.17 and Cassandra 4.1 as backends. Completed 2026-03-19.

---

## Architecture

```
VM: <VM_IP> (cortex-thehive)
User: admin / <VM_PASSWORD>
SSH from linux-host: ssh cortex-thehive

Docker Compose Stack:
  cassandra:4.1        - TheHive database
  elasticsearch:7.17   - Shared by TheHive (index) + Cortex (data)
  thehive:5.4          - :9000 - Case management
  cortex:3.1.8-1       - :9001 - Observable analysis engine

Network: thehive-cortex_default (containers reach each other by name)
Config:  ~/thehive-cortex/docker-compose.yml
Keys:    ~/thehive-cortex/api-keys.txt
```

---

## Step-by-Step Process

### 1. TheHive Admin Setup

TheHive 5.4 ships with default creds `admin@thehive.local` / `secret`.

**Login (get session cookie):**
```bash
curl -s -D - -X POST http://<VM_IP>:9000/api/v1/login \
  -H 'Content-Type: application/json' \
  -d '{"user":"admin@thehive.local","password":"secret"}'
# Extract THEHIVE-SESSION cookie from Set-Cookie header
```

**Change password:**
```bash
# IMPORTANT: Use the /password/change endpoint with currentPassword, NOT PATCH /user
printf '{"currentPassword":"secret","password":"NewPass123!"}' | \
curl -s -X POST "http://localhost:9000/api/v1/user/admin@thehive.local/password/change" \
  -H "Cookie: THEHIVE-SESSION=$SESSION" \
  -H 'Content-Type: application/json' -d @-
```

**Generate API key:**
```bash
curl -s -X POST "http://localhost:9000/api/v1/user/admin@thehive.local/key/renew" \
  -H "Cookie: THEHIVE-SESSION=$SESSION"
# Returns plain text API key
```

> [!warning] Gotcha: Password Change Endpoint
> `PATCH /api/v1/user/<login>` with `{"password":"..."}` returns 204 but **silently ignores the password field**. You MUST use `POST /api/v1/user/<login>/password/change` with `{"currentPassword":"old","password":"new"}`.

> [!warning] Gotcha: Bash Exclamation Marks
> Passwords with `!` cause JSON parse errors in curl due to bash history expansion. Always use `printf '...' | curl -d @-` instead of `-d '{"password":"Foo!"}'`.

---

### 2. Cortex First-Time Setup

Cortex 3.1.8 ships with zero users. The first-user endpoint is open when no users exist.

**Run DB migration (idempotent):**
```bash
curl -s -X POST http://<VM_IP>:9001/api/maintenance/migrate \
  -H 'Content-Type: application/json'
```

**Create superadmin (only works when no users exist):**
```bash
printf '{"login":"admin","name":"Admin","password":"NewPass123!","roles":["superadmin"]}' | \
curl -s -X POST http://<VM_IP>:9001/api/user \
  -H 'Content-Type: application/json' -d @-
```

**Login:**
```bash
printf '{"user":"admin","password":"NewPass123!"}' | \
curl -s -D - -X POST http://<VM_IP>:9001/api/login \
  -H 'Content-Type: application/json' -d @-
# Extract CORTEX_SESSION from Set-Cookie header
```

> [!danger] Gotcha: Cortex CSRF Protection (THE BIG ONE)
> Cortex uses Elastic4Play's custom CSRF filter. **All POST/PUT/PATCH/DELETE requests with session cookies require a CSRF token.** The initial user creation endpoint bypasses this (no auth needed), but everything after login is blocked without the token.
>
> **The CSRF mechanism (from reference.conf):**
> - Cookie name: `CORTEX-XSRF-TOKEN`
> - Header name: `X-CORTEX-XSRF-TOKEN`
>
> **How to get the token:**
> 1. Make any GET request with your session cookie
> 2. The response includes a `Set-Cookie: CORTEX-XSRF-TOKEN=<token>` cookie
> 3. Send that token back as BOTH a cookie AND the `X-CORTEX-XSRF-TOKEN` header
>
> ```bash
> # Step 1: Login, get session
> CORTEX_SESSION=$(printf '...' | curl -s -D - ... | grep CORTEX_SESSION | sed '...')
>
> # Step 2: GET request to receive CSRF cookie
> CSRF_TOKEN=$(curl -s -D - http://localhost:9001/api/user/admin \
>   -H "Cookie: CORTEX_SESSION=$CORTEX_SESSION" 2>&1 | \
>   grep 'CORTEX-XSRF-TOKEN' | sed 's/.*CORTEX-XSRF-TOKEN=//;s/;.*//')
>
> # Step 3: Use BOTH cookie + header on all mutating requests
> curl -s -X POST http://localhost:9001/api/organization \
>   -H "Cookie: CORTEX_SESSION=$CORTEX_SESSION; CORTEX-XSRF-TOKEN=$CSRF_TOKEN" \
>   -H "X-CORTEX-XSRF-TOKEN: $CSRF_TOKEN" \
>   -H 'Content-Type: application/json' \
>   -d '{"name":"MyOrg","description":"My organization","status":"Active"}'
> ```
>
> **Alternative:** Once you have an API key, use `Authorization: Bearer <key>` which bypasses CSRF entirely. The chicken-and-egg problem is generating that first API key.

**Create organization:**
```bash
curl -s -X POST http://localhost:9001/api/organization \
  -H "Cookie: CORTEX_SESSION=$SESSION; CORTEX-XSRF-TOKEN=$CSRF" \
  -H "X-CORTEX-XSRF-TOKEN: $CSRF" \
  -H 'Content-Type: application/json' \
  -d '{"name":"Neas","description":"Neas organization","status":"Active"}'
```

**Create org admin user:**
```bash
printf '{"name":"Neas Admin","roles":["read","analyze","orgadmin"],"organization":"Neas","login":"neas-admin"}' | \
curl -s -X POST http://localhost:9001/api/user \
  -H "Cookie: CORTEX_SESSION=$SESSION; CORTEX-XSRF-TOKEN=$CSRF" \
  -H "X-CORTEX-XSRF-TOKEN: $CSRF" \
  -H 'Content-Type: application/json' -d @-
```

**Generate API keys:**
```bash
# For org admin
curl -s -X POST http://localhost:9001/api/user/neas-admin/key/renew \
  -H "Cookie: CORTEX_SESSION=$SESSION; CORTEX-XSRF-TOKEN=$CSRF" \
  -H "X-CORTEX-XSRF-TOKEN: $CSRF"

# For superadmin
curl -s -X POST http://localhost:9001/api/user/admin/key/renew \
  -H "Cookie: CORTEX_SESSION=$SESSION; CORTEX-XSRF-TOKEN=$CSRF" \
  -H "X-CORTEX-XSRF-TOKEN: $CSRF"
```

---

### 3. TheHive-Cortex Integration

TheHive 5.4's Docker entrypoint supports Cortex config via CLI args - no need to mount an application.conf.

**Add to docker-compose.yml command:**
```yaml
command: [
  "--secret", "YOUR_SECRET",
  "--cql-hostnames", "cassandra",
  "--index-backend", "elasticsearch",
  "--es-hostnames", "elasticsearch",
  "--cortex-hostnames", "cortex",
  "--cortex-keys", "YOUR_CORTEX_ORG_ADMIN_API_KEY"
]
```

**Restart TheHive only:**
```bash
cd ~/thehive-cortex && docker compose up -d thehive
```

> [!tip] Best Practice
> Use the **org admin** API key (not superadmin) for the TheHive-Cortex connection. This follows least-privilege.

> [!info] Note
> TheHive takes ~15-30 seconds to fully start after container recreation. The entrypoint waits 30s for Cassandra, then generates a config file from CLI args and boots.

---

### 4. Generate TheHive API Key for External Access

```bash
curl -s -X POST "http://localhost:9000/api/v1/user/admin@thehive.local/key/renew" \
  -H "Cookie: THEHIVE-SESSION=$SESSION"
# Returns plain text API key
```

**Verify:**
```bash
curl -s http://<VM_IP>:9000/api/v1/user/current \
  -H 'Authorization: Bearer YOUR_API_KEY'
```

---

### 5. MCP Server Setup (thehive-mcp-ts)

**Clone and build:**
```bash
git clone https://github.com/solomonneas/thehive-mcp.git
cd thehive-mcp && npm install && npm run build
```

**Environment:**
```
THEHIVE_URL=http://<VM_IP>:9000
THEHIVE_API_KEY=<your-api-key>
```

**Claude Code MCP config:**
```json
{
  "mcpServers": {
    "thehive": {
      "command": "node",
      "args": ["/path/to/thehive-mcp/dist/index.js"],
      "env": {
        "THEHIVE_URL": "http://<VM_IP>:9000",
        "THEHIVE_API_KEY": "<your-api-key>"
      }
    }
  }
}
```

---

## Current Credentials

| Service | User | Password | API Key |
|---|---|---|---|
| TheHive | admin@thehive.local | (set during setup) | (generated by setup.sh) |
| Cortex (superadmin) | admin | (set during setup) | (generated by setup.sh) |
| Cortex (org admin) | neas-admin | (no password) | (generated by setup.sh) |

Keys also saved on VM at `~/thehive-cortex/api-keys.txt`.

---

## Gotchas & Lessons Learned

1. **Cortex CSRF is the #1 blocker for automation.** The Play Framework CSRF filter blocks all mutating requests with session cookies. The token cookie name (`CORTEX-XSRF-TOKEN`) and header name (`X-CORTEX-XSRF-TOKEN`) are non-standard and buried in `reference.conf` inside the container. Standard Play Framework CSRF bypass headers (`Csrf-Token: nocheck`, `X-CSRF-TOKEN`, etc.) do NOT work.

2. **TheHive PATCH endpoint silently ignores password changes.** The `PATCH /api/v1/user/<login>` endpoint returns 204 but does not change the password. Use the dedicated `POST /password/change` endpoint.

3. **Bash `!` in passwords breaks curl JSON.** Always pipe JSON through `printf` or a heredoc when passwords contain special characters.

4. **TheHive auth uses cookies, not Bearer tokens for session endpoints.** The login endpoint returns a `Set-Cookie` header, not a JSON token. Use `Cookie:` header for subsequent requests (or use API keys with `Authorization: Bearer`).

5. **TheHive startup takes 15-30s.** After `docker compose up -d`, wait before hitting the API. The entrypoint sleeps 30s waiting for Cassandra.

6. **Cortex initial user creation is a one-shot.** The `POST /api/user` endpoint without auth only works when zero users exist. After the first user is created, all user creation requires auth + CSRF.

---

## Agent Automation Playbook

For future automated deployments, here's the optimal order of operations:

```
1. docker compose up -d
2. Wait for services (poll GET /api/status on both ports)
3. TheHive: Login with default creds -> change password -> generate API key
   - Use printf pipe for JSON with special chars
   - Use /password/change endpoint (not PATCH)
4. Cortex: POST /api/maintenance/migrate
5. Cortex: POST /api/user (create superadmin, no auth needed - first time only)
6. Cortex: Login -> GET any endpoint (capture CSRF cookie) -> use CSRF on all POSTs
7. Cortex: Create org -> create org admin -> generate API keys (all need CSRF)
8. Update docker-compose.yml: add --cortex-hostnames and --cortex-keys
9. docker compose up -d thehive (restart only TheHive)
10. Wait 30s, verify API keys work on both services
11. Save keys to api-keys.txt
```

**Key automation tips:**
- Always extract CSRF token from Cortex GET response cookies before any POST
- Use `Authorization: Bearer <key>` after generating the first API key to skip CSRF for remaining operations
- Poll health endpoints rather than using fixed sleeps
- The Cortex org admin key is what TheHive needs for integration (not superadmin)

---

## Useful Commands

```bash
# Check TheHive status
curl -s http://<VM_IP>:9000/api/v1/user/current -H 'Authorization: Bearer <KEY>'

# Check Cortex status
curl -s http://<VM_IP>:9001/api/status

# Check Cortex user with API key (bypasses CSRF)
curl -s http://<VM_IP>:9001/api/user/admin -H 'Authorization: Bearer <KEY>'

# View TheHive logs
ssh cortex-thehive "docker logs thehive --tail 50"

# View Cortex logs
ssh cortex-thehive "docker logs cortex --tail 50"

# Restart stack
ssh cortex-thehive "cd ~/thehive-cortex && docker compose restart"
```

---

*Created: 2026-03-19 | VM: <VM_IP> | Stack: TheHive 5.4 + Cortex 3.1.8*
