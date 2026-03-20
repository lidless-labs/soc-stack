# TheHive 5.4 + Cortex 3.1.8 Deployment

## Prerequisites
- A Hyper-V VM created with `scripts/create-vm.ps1` (or any Ubuntu 24.04 box with Docker)
- Docker and Docker Compose v2 installed (cloud-init handles this)
- SSH access to the VM

## Deploy

### 1. Copy the stack to the VM
```bash
scp -r stacks/thehive-cortex/ admin@<vm-ip>:~/thehive-cortex/
```

### 2. Configure
```bash
ssh admin@<vm-ip>
cd ~/thehive-cortex
cp config.env.template config.env
nano config.env  # set passwords and secret key
```

### 3. Start the stack
```bash
docker compose up -d
```

Services take 30-60 seconds to fully start (Cassandra is the bottleneck).

### 4. Run automated setup
```bash
./setup.sh
```

This handles everything:
- Waits for all services to be healthy
- Changes the TheHive default password
- Generates TheHive API key
- Creates Cortex superadmin (first-user endpoint)
- Handles the Cortex CSRF token dance
- Creates Cortex organization and org admin
- Generates Cortex API keys
- Wires TheHive -> Cortex integration in docker-compose.yml
- Saves all credentials to `api-keys.txt`

### 5. Verify
```bash
# TheHive
curl -s http://localhost:9000/api/v1/user/current \
  -H "Authorization: Bearer $(grep 'API Key' api-keys.txt | head -1 | awk '{print $NF}')"

# Cortex
curl -s http://localhost:9001/api/status
```

## Ports
| Service       | Port |
|---------------|------|
| TheHive       | 9000 |
| Cortex        | 9001 |
| Elasticsearch | 9200 (internal only) |
| Cassandra     | 9042 (internal only) |

## Gotchas
See `docs/gotchas.md` for the full list. Key ones for this stack:

1. **Cortex CSRF is required for all POST requests with session cookies.** The setup.sh handles this, but if you're making manual API calls, you need the CSRF token dance (see reference docs).

2. **TheHive password change uses POST /password/change, not PATCH /user.** The PATCH endpoint silently ignores password fields.

3. **Use `printf` for passwords with special characters.** Bash history expansion breaks `!` in curl `-d` arguments.

4. **TheHive takes 30-60s to start.** It waits for Cassandra internally.
