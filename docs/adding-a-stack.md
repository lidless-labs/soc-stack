# Adding a New Stack

## Directory Structure

Create a new directory under `stacks/`:

```
stacks/<stack-name>/
├── docker-compose.yml     # Docker Compose service definitions
├── setup.sh               # Post-boot automation script
├── deploy.md              # Human-readable deployment guide
└── config.env.template    # Environment variables with sane defaults, copied to .env
```

## Spec File

Create `specs/<stack-name>.json`:

```json
{
  "name": "<stack-name>",
  "description": "What this stack does",
  "vm": {
    "name": "<stack-name>",
    "cores": 2,
    "ram_gb": 4,
    "disk_gb": 40
  },
  "stack": "stacks/<stack-name>",
  "services": {
    "<service>": {
      "port": 8080,
      "version": "latest",
      "default_user": "admin",
      "default_password": "changeme"
    }
  }
}
```

The `vm` section is read by `create-vm.ps1` when `--SpecFile` is passed.

## setup.sh Requirements

Every setup.sh must:

1. **Wait for services to be healthy.** Poll HTTP endpoints, don't use fixed sleeps.
2. **Be idempotent.** Running it twice should be safe (detect if setup already completed).
3. **Handle password gotchas.** Use `printf` for JSON with special characters.
4. **Save credentials to `api-keys.txt`.** Consistent location, `chmod 600`.
5. **Print a summary.** URLs, credentials, and verification commands.

Template:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# Wait for service
info "Waiting for <service>..."
while ! curl -sf http://localhost:<port>/health >/dev/null 2>&1; do
    sleep 3
done

# Setup logic here...

# Save credentials
cat > ./api-keys.txt <<EOF
# Generated: $(date)
User: admin
Password: ${PASSWORD}
API Key: ${API_KEY}
EOF
chmod 600 ./api-keys.txt
```

## Deployment Flow

The full workflow for any stack:

```
1. Build cloud-init ISO:     ./cloud-init/build-iso.sh <vm-name> <password>
2. SCP ISO to hyperv-host:       scp /tmp/<vm-name>-cidata.iso hyperv-host:C:/Users/user/Downloads/
3. Create VM (on hyperv-host):   .\create-vm.ps1 -VMName <vm-name> -CloudInitISO <path> [-SpecFile <path>]
4. Find VM IP:               .\find-vm-ip.ps1 -VMName <vm-name>
5. SCP stack to VM:          scp -r stacks/<stack-name>/ admin@<ip>:~/<stack-name>/
6. SSH in and deploy:        ssh admin@<ip> "cd ~/<stack-name> && cp config.env.template .env && docker compose up -d && ./setup.sh"
```

## Testing

Before submitting:
- Deploy on a fresh VM (don't test on an already-configured one)
- Run setup.sh twice (idempotency check)
- Verify all credentials in api-keys.txt work
- Check `docker compose ps` shows all services healthy
- Test from another machine (not just localhost)
