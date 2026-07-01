<p align="center">
  <img src="docs/assets/soc-stack-banner.jpg" alt="soc-stack banner" width="900">
</p>

<h1 align="center">SOC Stack</h1>

<p align="center">
  <strong>One command on a Proxmox host builds a complete, self-hosted Security Operations Center lab in about 30 minutes.</strong>
</p>

<p align="center">
  <a href="https://lidless.dev/soc-stack"><strong>lidless.dev/soc-stack</strong></a>
</p>

<p align="center">
  <img src="https://shieldcn.dev/github/ci/lidless-labs/soc-stack.svg?branch=main&workflow=ci.yml" alt="CI status">
  <img src="https://shieldcn.dev/github/release/lidless-labs/soc-stack.svg" alt="Latest release">
  <img src="https://shieldcn.dev/badge/license-MIT-green.svg" alt="MIT License">
</p>

<p align="center">
  <img src="https://shieldcn.dev/badge/Proxmox_VE-LXC-E57000.svg?logo=proxmox&logoColor=white" alt="Proxmox VE LXC">
  <img src="https://shieldcn.dev/badge/Wazuh-SIEM%2FXDR-4DAA50.svg" alt="Wazuh">
  <img src="https://shieldcn.dev/badge/TheHive_%2B_Cortex-Case_%2B_SOAR-f59e0b.svg" alt="TheHive and Cortex">
  <img src="https://shieldcn.dev/badge/MISP-Threat_Intel-7c3aed.svg" alt="MISP">
  <img src="https://shieldcn.dev/badge/Zeek_%2B_Suricata-NSM%2FIDS-2a5db0.svg" alt="Zeek and Suricata">
  <img src="https://shieldcn.dev/badge/MCP-9_servers-555.svg" alt="MCP servers">
  <img src="https://shieldcn.dev/badge/Docker_Compose-stacks-2496ED.svg?logo=docker&logoColor=white" alt="Docker Compose stacks">
  <img src="https://shieldcn.dev/badge/Bash-installers-4EAA25.svg?logo=gnubash&logoColor=white" alt="Bash installers">
</p>

SOC Stack is a one-command installer that stands up a full open-source Security Operations Center on a single Proxmox host: Wazuh, TheHive + Cortex, MISP, Zeek + Suricata, dashboards, and a row of MCP servers, all wired together. You want a realistic SOC to train on, test detections against, or run as a homelab, but assembling six tools by hand and integrating them eats days. It differs from a pile of per-tool guides by treating the whole stack as one declarative, idempotent, agent-friendly deploy: each tool is a self-contained LXC component, cross-component integrations wire automatically, and the entire run is non-interactive with JSON output so an AI agent can SSH in and one-shot it.

**Website:** [lidless.dev/soc-stack](https://lidless.dev/soc-stack)

> **Project status.** v1.0.0 is tagged and the full stack deploys and asserts green end-to-end on Proxmox VE 7.x/8.x/9.x. It is an actively developed, single-maintainer lab tool built for homelabs, training, and internal SOC replication, not a hardened multi-tenant production deployment. See [SECURITY.md](SECURITY.md) for the threat model and the [CHANGELOG](CHANGELOG.md) for what is in flight.

## What it does

SOC Stack is a self-hosted SOC lab builder for homelabs and security training. Run one command on a Proxmox VE host and roughly 30 minutes later you have a working Security Operations Center:

- **Wazuh** for SIEM / XDR (alerting, FIM, vulnerability detection, agent management)
- **TheHive + Cortex** for case management and SOAR (analyzers, responders, observable enrichment)
- **MISP** for threat intelligence (IOC sharing, feeds, correlation)
- **Zeek + Suricata** for network security monitoring and intrusion detection (NSM + IDS/IPS)
- **Custom dashboards** (Bro Hunter + Playbook Forge) behind nginx
- **9 MCP servers** so an AI agent can query Wazuh, TheHive, Cortex, MISP, Zeek, Suricata, MITRE ATT&CK, Rapid7, and Sophos over a single MCP config

Every tool runs in its own dedicated, unprivileged LXC. The orchestrator handles VMID allocation, network setup, idempotency, secret generation, and cross-component integration wiring. The whole run is non-interactive by default and emits structured JSON, so a person or an agent can replicate the same lab on demand.

Keywords: SOC lab, security operations center, Proxmox homelab, Wazuh SIEM, TheHive, Cortex SOAR, MISP threat intelligence, Suricata IDS, Zeek NSM, blue team training, detection engineering, self-hosted security, MCP servers for security tooling.

## Quick start

**Full stack** (every component, sensible defaults):

```bash
curl -sSL https://raw.githubusercontent.com/solomonneas/soc-stack/main/install.sh | sudo bash
```

When run from a local TTY as `sudo bash install.sh`, the installer opens a component picker if you did not pass `--components` or `--manifest`. Piped, CI, and agent-driven installs remain non-interactive and default to the full stack.

**Custom subset:**

```bash
curl -sSL https://raw.githubusercontent.com/solomonneas/soc-stack/main/install.sh | sudo bash -s -- \
  --components wazuh,thehive-cortex,misp \
  --preset standard \
  --bridge vmbr0 --storage local-lvm
```

**Agent-driven** (fully non-interactive, structured output):

```bash
curl -sSL https://raw.githubusercontent.com/solomonneas/soc-stack/main/install.sh | sudo bash -s -- \
  --components all \
  --preset minimal \
  --bridge vmbr0 --storage local-lvm --ip-mode dhcp \
  --json-out /root/soc-stack.json \
  --mcp-config-out /root/mcp-clients.json
```

Prefer to read before you run? Clone the repo and execute the same orchestrator locally; the behavior is identical:

```bash
git clone https://github.com/solomonneas/soc-stack.git
cd soc-stack
sudo bash install.sh --components all --dry-run   # validate + plan, deploy nothing
```

After install:
- `/root/soc-stack.json` lists every component with its LXC VMID, IP, ports, endpoints, warnings, and secret file paths. Raw passwords and API tokens are redacted by default; pass `--include-secrets-json` only when an automation workflow explicitly needs them.
- `/root/mcp-clients.json` is a paste-ready `mcpServers` config block for Claude Desktop, OpenClaw, or any MCP client. It contains bearer tokens and is written root-only.
- `/var/lib/soc-stack/state/` has per-component state files used for idempotent re-runs.
- `/var/lib/soc-stack/secrets/` has every generated credential (mode 0600, root-only) for audit recovery.

Re-run the same command with `--force` to redeploy a completed component, or with `--components <one>` to add a single component to an existing install.

## Components

| Component | Services | LXC preset (minimal) | Ports |
|---|---|---|---|
| **wazuh** | Wazuh Manager, Indexer, Dashboard | 2 vCPU, 2 GB RAM, 30 GB | 443, 1514, 1515, 55000 |
| **thehive-cortex** | TheHive 5.4, Cortex 3.1.8, Elasticsearch 7.17, Cassandra 4.1 | 2 vCPU, 4 GB RAM, 30 GB | 9000, 9001 |
| **misp** | MISP, MariaDB 10.11, Redis 7, misp-modules | 1 vCPU, 2 GB RAM, 20 GB | 443 |
| **zeek-suricata** | Zeek (NSM), Suricata (IDS/IPS) | 1 vCPU, 2 GB RAM, 20 GB | 47760 |
| **dashboards** | Bro Hunter + Playbook Forge behind nginx | 1 vCPU, 1 GB RAM, 10 GB | 80, 5174, 5177 |
| **mcp** | 9 MCP servers (wazuh, thehive, cortex, misp, zeek, suricata, mitre, rapid7, sophos) wrapped as SSE via `mcp-proxy` | 1 vCPU, 1 GB RAM, 10 GB | 3001-3009 |

Each component runs in its own dedicated LXC. Components can be deployed independently or together. The orchestrator handles VMID allocation, network setup, idempotency, and cross-component integration wiring.

## Cross-component integrations

Configured automatically after all components deploy:

- **Wazuh -> TheHive**: Wazuh alerts at level 8+ forward to TheHive as alerts via a custom Python integration (`/var/ossec/integrations/custom-thehive.py`).
- **TheHive <-> Cortex**: TheHive's Cortex connector points at the local Cortex with an org-scoped API key.
- **MISP -> Suricata**: hourly cron pulls Snort/Suricata rules from MISP's `restSearch` endpoint into Suricata's update.d.
- **Zeek -> Wazuh**: Wazuh agent runs in the zeek-suricata LXC and forwards conn.log, dns.log, http.log, ssl.log, notice.log to the Wazuh manager.
- **MCP servers <- all peers**: each MCP server's env file is populated with its corresponding tool's URL + API key from peer state.

## What a finished install looks like

`/root/soc-stack.json` is the source of truth for what got deployed. With secrets redacted, a full-stack run reports each component, its LXC, its endpoints, and any warnings (IPs and tokens below are placeholder values from the [RFC 5737](https://datatracker.ietf.org/doc/html/rfc5737) documentation range):

```json
{
  "version": "1.0.0",
  "preset": "minimal",
  "status": "deployed",
  "components": [
    {
      "component": "wazuh",
      "status": "deployed",
      "vmid": 9001,
      "ip": "192.0.2.11",
      "endpoints": { "dashboard": "https://192.0.2.11:443", "api": "https://192.0.2.11:55000" },
      "credentials": { "user": "admin", "password": "REDACTED" }
    },
    {
      "component": "mcp",
      "status": "deployed",
      "vmid": 9006,
      "ip": "192.0.2.16",
      "endpoints": { "wazuh_sse": "http://127.0.0.1:3001/sse", "thehive_sse": "http://127.0.0.1:3002/sse" }
    }
  ],
  "integrations": [
    { "from": "wazuh", "to": "thehive", "status": "wired" },
    { "from": "misp", "to": "suricata", "status": "wired" }
  ]
}
```

The exact result-JSON schema is documented in [`docs/design/specs/2026-05-15-soc-stack-unification-design.md`](docs/design/specs/2026-05-15-soc-stack-unification-design.md).

## Agent-friendly contract

Designed so an AI agent can SSH into a Proxmox host and one-shot a SOC. The full agent surface:

- **Stdin is closed** under `curl | sudo bash`; the installer auto-detects this and enables `--non-interactive` mode. Every prompt becomes a flag, every default becomes an answer.
- **Exit codes** are stable: 0 = success, 1 = preflight (bad host), 2 = validation (bad flags), 3 = component failed, 4 = integration failed, 5 = mixed state.
- **Result JSON schema** is documented in [`docs/design/specs/2026-05-15-soc-stack-unification-design.md`](docs/design/specs/2026-05-15-soc-stack-unification-design.md).
- **Idempotency**: re-running with the same flags exits in seconds if everything is already deployed (`status: "deployed"` in state). `--force` triggers redeploy.
- **Manifest mode**: instead of dozens of flags, write a JSON manifest and pass `--manifest <path>`. CLI flags applied on top override individual manifest fields.

## Flag reference

```
--components LIST     CSV of components or "all" (default: all)
--preset NAME         minimal | standard | production (default: standard)
--bridge NAME         Proxmox bridge (default: vmbr0)
--storage NAME        Storage pool (default: auto-detect)
--ip-mode MODE        dhcp or static (default: dhcp)
--ip-range CIDR       Required if --ip-mode=static (e.g., 198.51.100.10/24)
--vlan TAG            Optional VLAN tag
--vmid-start N        First VMID to allocate (default: next free)
--manifest PATH       JSON manifest (alternative to flags)
--state-dir PATH      State directory (default: /var/lib/soc-stack)
--json-out PATH       Result JSON path (default: /root/soc-stack.json)
--mcp-config-out PATH MCP client config (default: /root/mcp-clients.json)
--log-file PATH       Install log (default: /var/log/soc-stack-install.log)
--dry-run             Validate + plan only, no deploy
--force               Redeploy components already marked deployed
--no-integrate        Skip cross-component wiring phase
--non-interactive     Hard-fail on prompts (auto when stdin is not a TTY)
--include-secrets-json
                       Include raw credentials in result JSON (default: redacted)
--mcp-bind-host HOST   MCP SSE bind host (default: 127.0.0.1; use 0.0.0.0 to expose)
--version             Print version and exit
```

## Repository structure

```
soc-stack/
├── install.sh                  # repo-root wrapper for curl|bash
├── scripts/
│   ├── install.sh              # orchestrator (~430 lines)
│   ├── lib/                    # 8 shared bash modules (bats-tested)
│   │   ├── logging.sh
│   │   ├── secrets.sh
│   │   ├── json-out.sh
│   │   ├── idempotency.sh
│   │   ├── network.sh
│   │   ├── manifest.sh
│   │   ├── preflight.sh
│   │   └── lxc.sh
│   └── components/
│       ├── wazuh/              # manifest.jsonc + 5 scripts per component
│       ├── thehive-cortex/
│       ├── misp/
│       ├── zeek-suricata/
│       ├── dashboards/
│       └── mcp/                # 9 MCP servers + mcp-proxy SSE bridge
├── tests/
│   ├── unit/                   # 105 bats tests, mocked Proxmox binaries
│   └── integration/            # per-component + cross-component assertions
├── docs/
│   ├── design/specs/           # design spec (result JSON schema lives here)
│   ├── gotchas.md
│   ├── adding-a-component.md   # component contract walk-through
│   └── architecture/
├── playbooks/                  # incident response playbooks
├── cases/                      # case study evidence
└── mcp-servers/
    └── README.md               # docs for the 9 bundled MCP servers
```

## How it works

Each component is a self-contained folder under `scripts/components/<name>/` with a fixed interface:

| File | Runs where | Purpose |
|---|---|---|
| `manifest.jsonc` | (declarative) | Presets, ports, deps, provides |
| `lxc-spec.sh` | Proxmox host | Emits `pct create` flags per preset |
| `deploy.sh` | inside LXC | Idempotent installer; writes state JSON |
| `verify.sh` | inside LXC | Health check; exit 0 if healthy |
| `integrate.sh` | Proxmox host | Wires this component to peers (reads peer state) |
| `destroy.sh` | Proxmox host | Tears down the LXC + state |

The orchestrator (`scripts/install.sh`) only talks to components through this interface. Adding a new component means dropping in a new folder; nothing else changes.

State files in `/var/lib/soc-stack/state/<name>.json` are the source of truth for idempotency. Re-running `install.sh` checks each component's state and skips anything already deployed (unless `--force`). On failure, the state file records `status: "failed"` and an `error` string; the orchestrator continues with remaining independent components and reports mixed-state exit code 5.

## Prerequisites

- Proxmox VE 7.x or 8.x or 9.x host
- Root access on the Proxmox host
- A bridge (default: `vmbr0`) and a storage pool (default: auto-detect, falls back to `local-lvm`)
- Outbound HTTPS for installer downloads (Docker, Wazuh installer, MCP server repos, etc.)
- ~12 GB free RAM and ~150 GB free disk for the full stack at `--preset minimal`

The installer auto-installs `jq`, `curl`, `wget`, and `openssl` if missing.

## Operations

**Re-run for a single component:**
```bash
sudo bash install.sh --components misp --force
```

**Re-run the integration phase (after fixing a peer):**
```bash
sudo bash install.sh --components all
```
Already-deployed components are skipped by the idempotency check, so a plain re-run goes straight to cross-component wiring.

**Validate without deploying:**
```bash
sudo bash install.sh --components all --dry-run
```

**Remove a single component:**
```bash
sudo bash scripts/components/misp/destroy.sh
```
This stops and destroys the component's LXC and removes its state file. Other components keep running; re-run the installer afterwards if peers should drop their wiring to it.

**Tear down everything:**
```bash
for comp in mcp dashboards zeek-suricata misp thehive-cortex wazuh; do
  sudo bash scripts/components/${comp}/destroy.sh
done
sudo rm -rf /var/lib/soc-stack /root/soc-stack.json /root/mcp-clients.json
```
The final `rm` removes state, generated secrets, and the emitted JSON; skip it if you want credential recovery later.

**Upgrade:**
```bash
curl -sSL https://raw.githubusercontent.com/solomonneas/soc-stack/main/install.sh | sudo bash
```
Re-running the installer from a newer checkout is the upgrade path: already-deployed components are left alone, new components deploy, and integration re-wires. To pick up a new version of one component, destroy it and re-run with `--components <name>`. The installer never auto-updates a running component in place.

## Why not something else?

- **Why not install each tool by hand?** You can, and the official docs for Wazuh, TheHive, MISP, and Suricata are good. But six installs plus the integrations between them (alert forwarding, analyzer wiring, IOC feeds, log shipping) is a multi-day project that breaks the next time you rebuild. SOC Stack makes the whole thing one reproducible command.
- **Why not a single all-in-one SIEM VM (SecurityOnion, Wazuh OVA, etc.)?** Those are excellent and purpose-built. SOC Stack is different on purpose: each tool lives in its own LXC you can scale, snapshot, or destroy independently, the components are the real upstream projects (not a fork), and the cross-tool integrations are explicit and inspectable rather than baked into one appliance.
- **Why not Ansible or Terraform?** Nothing stops you, and a config-management rewrite is a reasonable future direction. The current design favors plain, auditable bash you can read top to bottom and a `curl | sudo bash` path an agent can drive without extra tooling on the host. State files, not a state backend, drive idempotency.
- **Why not run it on Docker / Kubernetes directly?** Several components already use Docker Compose inside their LXC. The Proxmox LXC layer gives each tool isolation, its own IP, and snapshot/rollback at the container level, which matches how a homelab SOC is actually operated.

## What soc-stack is not

- **Not a hardened production SOC.** It is a lab and training tool. It assumes a trusted Proxmox host and a trusted internal bridge. Do not expose the component IPs to an untrusted network without a firewall, VLAN, and TLS termination in front. The full threat model is in [SECURITY.md](SECURITY.md).
- **Not a managed or hosted service.** There is no SaaS, no telemetry, and no phone-home. Everything runs on hardware you control.
- **Not a fork or a repackage of the upstream tools.** It deploys Wazuh, TheHive, Cortex, MISP, Zeek, and Suricata from their real sources at pinned versions; it does not modify them.
- **Not an auto-updater.** The installer pins versions and never silently upgrades a running component in place; updates happen on your schedule.
- **Not multi-host.** It targets a single Proxmox host. Multi-node is out of scope today.

## Adding a new component

See [docs/adding-a-component.md](docs/adding-a-component.md) for the component contract walk-through, and [docs/design/specs/2026-05-15-soc-stack-unification-design.md](docs/design/specs/2026-05-15-soc-stack-unification-design.md) for the full design.

## Contributing

Contributions are welcome. New components follow a six-file contract, every lib function gets a bats test, and CI runs shellcheck plus bats on every PR. Start with [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md).

## Security

Default credentials are rotated and verified on deploy, secrets are root-only, result JSON is redacted by default, and MCP servers bind to localhost unless you say otherwise. The full threat model, what is hardened versus deliberately accepted, lives in [SECURITY.md](SECURITY.md). Found a vulnerability? Use GitHub's private vulnerability reporting on this repository.

## License

[MIT](LICENSE). Copyright (c) 2026 Solomon Neas.
