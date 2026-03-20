# SOC Stack

A unified deployment toolkit for security operations tools. One command per tool, fully unattended from VM creation to API key generation.

Deploys security tool stacks on **Hyper-V VMs** using Ubuntu 24.04 cloud images and Docker Compose. PowerShell scripts run on the Windows Hyper-V host (hyperv-host), bash scripts run on the VMs or on the Linux utility server (linux-host).

## Quick Start

```bash
# 1. Build cloud-init ISO (on linux-host/Linux)
./cloud-init/build-iso.sh thehive-cortex 'MyPassword!' ~/.ssh/id_ed25519.pub

# 2. SCP ISO to Hyper-V host
scp /tmp/thehive-cortex-cidata.iso hyperv-host:C:/Users/user/Downloads/

# 3. Create VM (on hyperv-host, elevated PowerShell)
.\scripts\create-vm.ps1 -VMName "thehive-cortex" `
    -SpecFile ".\specs\thehive-cortex.json" `
    -CloudInitISO "C:\Users\user\Downloads\thehive-cortex-cidata.iso"

# 4. Find VM IP
.\scripts\find-vm-ip.ps1 -VMName "thehive-cortex"

# 5. Deploy the stack
scp -r stacks/thehive-cortex/ admin@<ip>:~/thehive-cortex/
ssh admin@<ip> "cd ~/thehive-cortex && cp config.env.template config.env && docker compose up -d && ./setup.sh"
```

setup.sh handles everything: waits for services, changes default passwords, generates API keys, wires integrations, saves credentials to `api-keys.txt`.

## Supported Stacks

| Stack | Services | Status |
|-------|----------|--------|
| [thehive-cortex](stacks/thehive-cortex/) | TheHive 5.4, Cortex 3.1.8, Elasticsearch 7.17, Cassandra 4.1 | Ready |
| [misp](stacks/misp/) | MISP (latest), MariaDB 10.11, Redis 7 | Ready |
| wazuh | Wazuh 4.x (SIEM/XDR) | Planned |
| zeek-suricata | Zeek + Suricata (NSM/IDS) | Planned |
| opencti | OpenCTI (Threat Intelligence) | Planned |

## Repository Structure

```
soc-stack/
├── README.md
├── scripts/
│   ├── create-vm.ps1          # Hyper-V VM creation (cloud image -> VHDX -> VM)
│   ├── destroy-vm.ps1         # Clean teardown (stop VM, delete VHDX)
│   └── find-vm-ip.ps1        # ARP scan for Hyper-V MAC prefix
├── cloud-init/
│   ├── base-user-data.yaml    # Template: users, packages, docker
│   ├── base-meta-data.yaml    # Template: instance-id, hostname
│   ├── base-network-config.yaml # hv_netvsc DHCP config (CRITICAL)
│   └── build-iso.sh          # genisoimage wrapper (runs on Linux)
├── stacks/
│   ├── thehive-cortex/
│   │   ├── docker-compose.yml
│   │   ├── setup.sh          # Automated: accounts, API keys, integration
│   │   ├── deploy.md
│   │   └── config.env.template
│   ├── misp/
│   │   ├── docker-compose.yml
│   │   ├── setup.sh
│   │   ├── deploy.md
│   │   └── config.env.template
│   ├── wazuh/                 # Planned
│   ├── zeek-suricata/         # Planned
│   └── opencti/               # Planned
├── specs/
│   ├── defaults.json          # Default switch, image path, credentials
│   ├── thehive-cortex.json    # VM specs + service metadata
│   └── misp.json
├── docs/
│   ├── gotchas.md             # Consolidated from production deployments
│   └── adding-a-stack.md      # How to add a new tool
├── reference/
│   └── hyper-v/
│       ├── vm-automation-guide.md
│       └── thehive-cortex-setup-guide.md
├── playbooks/                 # Incident response playbooks
├── cases/                     # Case study evidence
└── mcp-servers/               # MCP server connectors (separate concern)
```

## Design Decisions

1. **PowerShell on Windows, Bash on Linux.** `create-vm.ps1` runs on the Hyper-V host (hyperv-host). `build-iso.sh` and `setup.sh` run on Linux. No mixing.

2. **Spec files define VM requirements.** `create-vm.ps1` reads JSON specs for cores, RAM, disk. Human-readable and version-controlled.

3. **setup.sh per stack.** Each stack has a setup script that handles everything post-SSH: docker compose up, wait for health, create accounts, generate keys, wire integrations. This is where all the gotchas live (CSRF tokens, password endpoints, buffer sizes).

4. **config.env.template files.** Sane defaults, copy to `config.env` and customize. Not committed to git.

5. **Shared cloud-init templates.** Base user-data, meta-data, and network-config are shared. Stack-specific packages can be added via the spec file or manually.

## Prerequisites

**On the Hyper-V host (hyperv-host / Windows):**
- Hyper-V enabled
- qemu-img installed (`choco install qemu -y`)
- A Hyper-V virtual switch (`DNS-NIC-Switch` by default)

**On the Linux utility server (linux-host):**
- genisoimage (`apt install genisoimage`)
- SSH access to the Hyper-V host
- Ubuntu 24.04 cloud image downloaded

**On each VM (handled by cloud-init):**
- Docker and Docker Compose v2
- SSH access as `admin`

## Gotchas

See [docs/gotchas.md](docs/gotchas.md) for the full list. The highlights:

- **Remove the VHDX sparse flag BEFORE Resize-VHD** or Hyper-V refuses to start the VM
- **Include network-config with `match: driver: hv_netvsc`** or the VM gets zero network
- **Cortex CSRF requires a token dance** on every POST after login
- **TheHive password change uses POST /password/change**, not PATCH /user
- **Set INNODB_BUFFER_POOL_SIZE=512M** for MISP on 4GB VMs or MariaDB OOMs

## Adding a New Stack

See [docs/adding-a-stack.md](docs/adding-a-stack.md).

## License

MIT
