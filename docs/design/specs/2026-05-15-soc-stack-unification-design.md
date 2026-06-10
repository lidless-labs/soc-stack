# SOC Stack Unification Design

**Date:** 2026-05-15
**Status:** Draft - pending implementation plan
**Authors:** Solomon Neas

## Context

The repo currently ships three disconnected deployment narratives: a unified Proxmox installer (`scripts/setup/install.sh`, ~800 lines, not mentioned in README), per-tool Proxmox LXC one-liners (`proxmox/ct/*.sh`, only thehive-cortex and misp), and a Hyper-V path (`scripts/create-vm.ps1` + cloud-init + per-tool specs). The README pitches the per-tool and Hyper-V paths, marks wazuh/zeek-suricata/opencti as "Planned", and never mentions the unified installer. The unified installer actually installs wazuh, zeek, suricata, custom dashboards (Bro Hunter + Playbook Forge), and references 9 MCP servers in external repos - none of which the README acknowledges.

The original intent was a single Proxmox helper script that a human or an AI agent can run once on a Proxmox host to stand up a complete SOC, end to end. The current state buries that intent under leftover code from abandoned framings.

## Goal

Make one path - `install.sh` - the only path. Designed so an agent can SSH into a Proxmox host and run a single non-interactive command that returns a parseable result describing every component, endpoint, credential, and integration it deployed.

## Non-goals

- OpenCTI support (deferred to v2; stub directory deleted)
- Hyper-V or any non-Proxmox deployment path
- Per-tool community-scripts.org-style one-liners (superseded by `install.sh --components <x>`)
- Rewriting any of the 9 MCP server repos themselves
- Security efficacy testing (we verify services come up and integrate, not that they catch threats)
- Long-term soak/chaos testing

## Decisions

| Topic | Decision |
|---|---|
| Canonical pitch | Proxmox-only one-shot installer |
| Agent interface | SSH + non-interactive bash flags, JSON output, creds at known path |
| v1 components | wazuh, thehive-cortex, misp, zeek-suricata, dashboards, mcp (9 servers) |
| OpenCTI | Deferred to v2; existing `.gitkeep` stub deleted |
| MCP deployment | Dedicated `s3-mcp` LXC, HTTP/SSE transport, paste-ready client config emitted |
| Install paradigm | Hybrid per-component (each uses vendor-recommended method inside its LXC) |
| Parallel paths | Hyper-V scripts, cloud-init, per-tool one-liners, Hyper-V specs all deleted |
| Code structure | Modular: thin orchestrator + shared lib + per-component folders |
| Agent input formats | Flags (for casual use) and `--manifest <path>` (for complex setups) |
| CI substrate | Self-hosted runner in dedicated LXC on a test Proxmox host; tests every PR + merge to main |

## Architecture

### Invocation contract

```bash
# Default: install everything sensible
curl -sSL https://raw.githubusercontent.com/solomonneas/soc-stack/main/install.sh \
  | sudo bash

# Agent-style, explicit
curl -sSL .../install.sh | sudo bash -s -- \
    --components wazuh,thehive-cortex,misp,zeek-suricata,dashboards,mcp \
    --preset standard \
    --bridge vmbr0 \
    --storage local-lvm \
    --ip-mode dhcp \
    --json-out /root/soc-stack.json \
    --mcp-config-out /root/mcp-clients.json

# Manifest mode (complex / repeatable)
curl -sSL .../install.sh | sudo bash -s -- --manifest /root/soc-stack-manifest.json
```

### Flags

| Flag | Default | Purpose |
|---|---|---|
| `--components` | `all` | CSV: wazuh, thehive-cortex, misp, zeek-suricata, dashboards, mcp |
| `--preset` | `standard` | `minimal` / `standard` / `production` |
| `--bridge` | `vmbr0` | Proxmox bridge |
| `--storage` | auto-detect | Storage pool |
| `--ip-mode` | `dhcp` | `dhcp` or `static` |
| `--ip-range` | - | required if `--ip-mode=static` (e.g., `198.51.100.10/24`) |
| `--vlan` | - | optional VLAN tag |
| `--vmid-start` | next available | first VMID to allocate; tests use `--vmid-start 9000` |
| `--manifest` | - | path to JSON manifest (alternative to flags) |
| `--state-dir` | `/var/lib/soc-stack` | per-component state files |
| `--json-out` | `/root/soc-stack.json` | final result JSON |
| `--mcp-config-out` | `/root/mcp-clients.json` | paste-ready MCP client config |
| `--log-file` | `/var/log/soc-stack-install.log` | install log |
| `--dry-run` | - | validate + plan, no deploy |
| `--force` | - | redeploy even if state shows complete |
| `--no-integrate` | - | skip cross-component wiring |
| `--non-interactive` | auto when stdin not a tty | hard-fail on any prompt |
| `--version` | - | print version and exit |

### Orchestration sequence

```
1. preflight()         — root check, Proxmox version >= 7, deps installed, bridge exists, storage exists
2. build_manifest()    — flags + defaults + per-component presets => internal manifest
3. validate()          — VMIDs available in requested range, IP range free, no port conflicts
4. plan()              — print intended actions; exit if --dry-run
5. for each component in dep order:
     a. is_completed?  => skip unless --force
     b. lxc_create()   => create + start LXC
     c. lxc_install()  => push and run components/<name>/deploy.sh inside LXC
     d. lxc_verify()   => run components/<name>/verify.sh; up to 3 retries × 30s
     e. state_persist() => write /var/lib/soc-stack/state/<name>.json
6. integrate()         — run components/<name>/integrate.sh for each (unless --no-integrate)
7. emit_results()      — write --json-out + --mcp-config-out, print summary
```

### Dependency order

Most components have no hard dependency on each other and could deploy in parallel. v1 installs them serially in this order for simplicity and predictable logs. Concurrent deploy is a v2 optimization.

| Component | Hard dep | Soft dep (integration only) |
|---|---|---|
| wazuh | - | - |
| thehive-cortex | - | - |
| misp | - | - |
| zeek-suricata | - | wazuh (for agent forwarding integration; runs standalone if wazuh absent) |
| dashboards | - | zeek-suricata (for log bind-mount; runs standalone if absent) |
| mcp | all others must exist | needs each component's URL + API key to configure 9 servers |

Only `mcp` has a hard dependency - its `deploy.sh` reads other components' state files to configure the 9 MCP server connections. Soft deps mean: if the target component is missing or failed, `integrate.sh` skips that specific wiring with a warning, but the component still deploys.

### Per-component module contract

Every component is a self-contained folder under `scripts/components/<name>/` with a fixed interface. The orchestrator knows nothing about Wazuh vs MISP internals.

```
scripts/components/<name>/
├── manifest.jsonc        # declarative: presets, ports, deps, integration handles
├── lxc-spec.sh           # emits LXC creation args (RAM/disk/cores/template/features)
├── deploy.sh             # runs inside the LXC; idempotent; installs the tool
├── integrate.sh          # runs on Proxmox host after all deploys; wires this comp to others
├── verify.sh             # runs inside LXC; exit 0 if healthy
└── destroy.sh            # clean teardown of this component
```

#### manifest.jsonc

```jsonc
{
  "name": "wazuh",
  "display_name": "Wazuh",
  "description": "SIEM/XDR platform",
  "depends_on": [],
  "provides": ["wazuh_url", "wazuh_api", "wazuh_agent_endpoint"],
  "presets": {
    "minimal":    { "ram_mb": 2048, "disk_gb": 30,  "cores": 1 },
    "standard":   { "ram_mb": 4096, "disk_gb": 50,  "cores": 2 },
    "production": { "ram_mb": 8192, "disk_gb": 100, "cores": 4 }
  },
  "ports": [443, 1514, 1515, 55000],
  "template": "ubuntu-22.04-standard",
  "features": ["nesting=1"],
  "unprivileged": true,
  "default_creds": { "user": "admin", "password": "admin", "rotate_on_install": true }
}
```

#### deploy.sh contract

Runs inside the LXC. Receives via env:

```
SOC_STATE_DIR        # bind-mounted from /var/lib/soc-stack/
SOC_COMPONENT        # "wazuh"
SOC_PRESET           # "standard"
SOC_NON_INTERACTIVE  # "1"
```

Required behavior:

1. Idempotent. Re-running is safe and a no-op if already deployed.
2. On success or already-deployed, writes `${SOC_STATE_DIR}/state/<name>.json`:
   ```json
   {
     "component": "wazuh",
     "status": "deployed",
     "url": "https://198.51.100.10",
     "api_url": "https://198.51.100.10:55000",
     "credentials": { "user": "admin", "password": "..." },
     "services": ["wazuh-manager", "wazuh-indexer", "wazuh-dashboard"]
   }
   ```
3. Exit 0 on success or already-deployed; non-zero on failure (with state file `status: "failed"` and `error` field).

#### integrate.sh contract

Runs on the Proxmox host after all components are deployed. Reads other components' state files, generates config, pushes to its own LXC. Idempotent: checks for marker in target config before applying.

If a dependency's state file shows `status: "failed"`, logs a warning and skips that specific integration. Does not fail the integration phase.

### State, output, and credentials

Three artifacts produced:

| File | Default path | Audience |
|---|---|---|
| Result JSON | `/root/soc-stack.json` | Agent / human - canonical summary |
| MCP client config | `/root/mcp-clients.json` | Paste into Claude Desktop / OpenClaw / Codex |
| State directory | `/var/lib/soc-stack/` | install.sh itself - idempotency + re-runs |

#### Result JSON schema

```json
{
  "version": "1.0",
  "installed_at": "2026-05-15T18:32:14Z",
  "soc_stack_version": "1.0.0",
  "proxmox": {
    "host": "pve.lab.local",
    "version": "8.2.4",
    "bridge": "vmbr0",
    "storage": "local-lvm"
  },
  "components": [
    {
      "name": "wazuh",
      "status": "deployed",
      "lxc": { "vmid": 201, "hostname": "s3-wazuh", "ip": "198.51.100.10" },
      "preset": "standard",
      "ports": [443, 1514, 1515, 55000],
      "endpoints": {
        "dashboard": "https://198.51.100.10",
        "api": "https://198.51.100.10:55000",
        "agent_enrollment": "198.51.100.10:1515"
      },
      "credentials": {
        "admin_user": "admin",
        "admin_password": "<generated>"
      }
    }
  ],
  "integrations": [
    { "from": "wazuh", "to": "thehive-cortex", "type": "webhook", "status": "configured" },
    { "from": "thehive", "to": "cortex", "type": "api", "status": "configured" },
    { "from": "misp", "to": "suricata", "type": "rule-feed", "status": "configured" },
    { "from": "zeek", "to": "wazuh", "type": "agent-forward", "status": "configured" }
  ],
  "warnings": [],
  "errors": []
}
```

#### MCP client config

```json
{
  "comment": "Paste the 'mcpServers' block into your client's config.",
  "mcpServers": {
    "wazuh":    { "type": "sse", "url": "http://198.51.100.99:3001/sse", "headers": { "Authorization": "Bearer <token>" } },
    "thehive":  { "type": "sse", "url": "http://198.51.100.99:3002/sse", "headers": { "Authorization": "Bearer <token>" } },
    "cortex":   { "type": "sse", "url": "http://198.51.100.99:3003/sse", "headers": { "Authorization": "Bearer <token>" } },
    "misp":     { "type": "sse", "url": "http://198.51.100.99:3004/sse", "headers": { "Authorization": "Bearer <token>" } },
    "zeek":     { "type": "sse", "url": "http://198.51.100.99:3005/sse", "headers": { "Authorization": "Bearer <token>" } },
    "suricata": { "type": "sse", "url": "http://198.51.100.99:3006/sse", "headers": { "Authorization": "Bearer <token>" } },
    "mitre":    { "type": "sse", "url": "http://198.51.100.99:3007/sse", "headers": { "Authorization": "Bearer <token>" } },
    "rapid7":   { "type": "sse", "url": "http://198.51.100.99:3008/sse", "headers": { "Authorization": "Bearer <token>" } },
    "sophos":   { "type": "sse", "url": "http://198.51.100.99:3009/sse", "headers": { "Authorization": "Bearer <token>" } }
  },
  "raw_endpoints": [
    { "name": "wazuh-mcp", "url": "http://198.51.100.99:3001/sse", "token": "<token>" }
  ]
}
```

`raw_endpoints` lets non-Claude clients iterate without parsing the `mcpServers` schema.

#### State directory layout

```
/var/lib/soc-stack/
├── manifest.json              # the effective manifest (flags merged with defaults)
├── state/
│   ├── wazuh.json
│   ├── thehive-cortex.json
│   ├── misp.json
│   ├── zeek-suricata.json
│   ├── dashboards.json
│   └── mcp.json
├── secrets/                   # mode 0600, root-owned
│   ├── wazuh-admin.txt
│   ├── thehive-admin.txt
│   ├── cortex-orgadmin.txt
│   ├── misp-admin.txt
│   ├── mcp-bearer-tokens.txt
│   └── ...
└── logs/
    ├── install-2026-05-15.log
    └── component-wazuh.log
```

Credentials live in two places by design: the result JSON (for agent retrieval) and `secrets/*.txt` (mode 0600, durable audit trail). State files are the source of truth for idempotency; the result JSON is regenerated every run as a view of state.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | All requested components deployed (or already deployed) and integrated |
| 1 | Pre-flight failed (not Proxmox, wrong version, missing deps, bad flags) |
| 2 | Validation failed (storage/bridge missing, VMIDs unavailable, port conflict) |
| 3 | One or more components failed during deploy |
| 4 | All components deployed but one or more integrations failed |
| 5 | Mixed state - some components succeeded, some failed |

### Shared lib

```
scripts/lib/
├── logging.sh          # msg_info, msg_ok, msg_error, msg_warn; writes to --log-file
├── lxc.sh              # lxc_create, lxc_start, lxc_wait_network, lxc_push_script, lxc_exec
├── idempotency.sh      # state_get, state_set, is_completed, mark_completed, clear_state
├── json-out.sh         # state_set <k> <v>, emit_final_json, emit_mcp_config
├── network.sh          # next_vmid, allocate_ip, validate_bridge
├── secrets.sh          # gen_password, store_secret, get_secret
├── manifest.sh         # parse_manifest, validate_manifest, merge_flags_into_manifest
└── preflight.sh        # check_root, check_proxmox_version, check_deps, check_bridge, check_storage
```

## Error handling and idempotency

### Rules

1. Every step asks "is this already done?" before doing it. No try-then-undo.
2. State files are the single source of truth.
3. `--force` is the only way to redeploy a completed component. Re-running without `--force` on a fully-deployed stack is a no-op that prints "all components already deployed" and exits 0.

### Idempotent primitives

`lxc_create` checks `pct status` first. `lxc_start` is a no-op if already running. `lxc_wait_network` is a bounded retry (30 × 2s). Package installs check `dpkg -l` before `apt install`. Docker compose checks `docker compose ps` before `up`. Service enable checks `systemctl is-enabled` first. Config edits grep for a marker before sed-in. Webhook integrations check for existing entry before adding.

### Partial failure model

When a component's `deploy.sh` fails:

1. Write `state/<name>.json` with `status: "failed"` and `error: "..."`.
2. Continue with remaining components that don't depend on the failed one. Skip those that do.
3. Skip integration phase for any failed component, but still wire integrations between successful ones.
4. Final result JSON lists what worked and what didn't.
5. Exit code 3 (component failed) or 5 (mixed state).

Worked example: agent runs all 6 components, MISP fails during docker compose pull, others succeed. Integration phase wires everything except MISP-related links. Exit 5. Agent re-runs `bash install.sh --components misp --force`. Second run only touches MISP, regenerates the MISP->Suricata integration after MISP comes up.

### Failure-mode policies

- **Network timeout in LXC:** `lxc_wait_network` retries 30 × 2s. If still no network, mark component failed and continue.
- **Service didn't start:** `verify.sh` runs `systemctl is-active` or `docker compose ps`. Up to 3 retries × 30s. If still not up, mark failed with the last `journalctl -u <svc>` line in the error message.
- **Integration target missing or failed:** Log warning, skip that specific integration. Don't fail the whole integration phase.

### What we explicitly do NOT do

- No automatic rollback on partial failure. Half-deployed LXCs stay in place for `pct enter` debugging. `destroy.sh` is opt-in.
- No retry-with-backoff for whole components. The agent retries by calling install.sh again with `--components <failed>`.
- No interactive prompts. `--non-interactive` is enforced when stdin isn't a TTY.

## Testing

Three layers, all automated. No manual test invocation required.

| Layer | Where | Trigger | Catches |
|---|---|---|---|
| 1. Shellcheck + bashate | GitHub Actions (ubuntu-latest) | every PR | syntax, unquoted vars, missing `set -euo pipefail` |
| 2. Bats unit tests (mocked `pct`/`qm`/`docker`) | GitHub Actions (ubuntu-latest) | every PR | shared lib logic, state machine, JSON schemas |
| 3. Integration tests on real LXCs | Self-hosted runner LXC on a test Proxmox host | every PR + merge to main | end-to-end |

### Test-host CI infrastructure (one-time setup)

```
Test Proxmox host
├── Dedicated LXC: soc-stack-ci-runner       # NEW
│   ├── github-runner systemd service
│   ├── SSH key to a sudoer user on the Proxmox host (for pct/qm/pvesm/pveam)
│   └── Labels: [self-hosted, soc-stack, proxmox]
└── Cron on Proxmox host: soc-stack-test-reaper.sh, every 15min
    └── Destroys any LXC in VMID 9000-9099 older than 90 minutes
```

The Proxmox host gains a `gh-runner` user with a sudoers entry scoped to `pct`, `qm`, `pvesm`, `pveam` only. The runner LXC has SSH key access as that user.

### Test resource budget

Assumed minimum: a Proxmox host with at least 16GB RAM free for tests. Integration tests use `--preset minimal`:

- wazuh 2GB, thehive-cortex 2GB, misp 2GB, zeek+suricata 1GB each, dashboards 1GB, mcp 1GB = ~10GB peak when all are running.
- VMID range `9000-9099` reserved for tests.
- Network: reuse the host's primary bridge (`vmbr0`); full isolation not required for v1.
- GitHub Actions concurrency group `soc-stack-integration` enforces serial runs across PRs.

### CI workflow shape

```yaml
on: [pull_request, push]
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  shellcheck:
    runs-on: ubuntu-latest
  unit-tests:
    runs-on: ubuntu-latest
  manifest-schema:
    runs-on: ubuntu-latest

  integration-tests:
    needs: [shellcheck, unit-tests]
    runs-on: [self-hosted, soc-stack]
    concurrency:
      group: soc-stack-integration
      cancel-in-progress: false
    strategy:
      fail-fast: false
      matrix:
        component: [wazuh, thehive-cortex, misp, zeek-suricata, dashboards, mcp]
      max-parallel: 2
    steps:
      - checkout
      - ./tests/integration/setup-test-env.sh ${{ matrix.component }}
      - ./install.sh --components ${{ matrix.component }} --preset minimal \
          --vmid-start 9000 --json-out /tmp/result.json
      - ./tests/integration/assert-${{ matrix.component }}.sh /tmp/result.json
      - ./tests/integration/destroy-test-env.sh ${{ matrix.component }}

  integration-full:                 # only on merge to main
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    needs: integration-tests
    runs-on: [self-hosted, soc-stack]
    steps:
      - ./install.sh --components all --preset minimal --vmid-start 9000 --json-out /tmp/full.json
      - ./tests/integration/assert-all-integrations.sh /tmp/full.json
      - ./install.sh --components all --preset minimal --vmid-start 9000 --force   # idempotency
      - ./tests/integration/destroy-test-env.sh --all
```

### What integration tests verify

- Per component: install succeeds, expected services running, expected ports listening, web UI responds, API authenticates with credentials from result JSON
- Per integration: wiring actually flows (Wazuh alert -> TheHive case, TheHive observable -> Cortex analyzer, MISP IOC -> Suricata rule, Zeek log -> Wazuh agent)
- Idempotency: full-stack re-run finishes in < 30s with no state changes
- Partial failure: injecting a fault produces correct exit code and populated `errors[]`
- Full destroy: `destroy.sh --all` removes all `s3-*` LXCs

### What we deliberately do NOT test

- Security efficacy (does Wazuh detect a real attack?)
- MCP server tool correctness (those have their own test suites in their own repos)
- Long-term stability / soak

## Repo restructure

### Final directory layout

```
soc-stack/
├── README.md                          # rewritten: one-shot Proxmox pitch
├── LICENSE
├── CONTRIBUTING.md                    # NEW - how to add a component
├── CHANGELOG.md                       # NEW - version history
├── install.sh                         # thin wrapper -> scripts/install.sh (for curl|bash idiom)
├── .github/
│   ├── workflows/ci.yml               # rewritten
│   ├── ISSUE_TEMPLATE/
│   │   ├── bug_report.md              # NEW
│   │   └── component_request.md       # NEW
│   ├── PULL_REQUEST_TEMPLATE.md       # NEW
│   └── FUNDING.yml
├── scripts/
│   ├── install.sh                     # ~250-line orchestrator
│   ├── lib/
│   │   ├── logging.sh
│   │   ├── lxc.sh
│   │   ├── idempotency.sh
│   │   ├── json-out.sh
│   │   ├── network.sh
│   │   ├── secrets.sh
│   │   ├── manifest.sh
│   │   └── preflight.sh
│   └── components/
│       ├── wazuh/
│       ├── thehive-cortex/
│       ├── misp/
│       ├── zeek-suricata/
│       ├── dashboards/
│       └── mcp/
├── tests/
│   ├── unit/
│   │   ├── test_idempotency.bats
│   │   ├── test_network.bats
│   │   ├── test_secrets.bats
│   │   ├── test_manifest.bats
│   │   └── fixtures/bin/              # fake pct, qm, docker
│   └── integration/
│       ├── setup-test-env.sh
│       ├── destroy-test-env.sh
│       ├── assert-wazuh.sh
│       ├── assert-thehive-cortex.sh
│       ├── assert-misp.sh
│       ├── assert-zeek-suricata.sh
│       ├── assert-dashboards.sh
│       ├── assert-mcp.sh
│       ├── assert-all-integrations.sh
│       └── soc-stack-test-reaper.sh
├── tools/
│   ├── setup-ci-runner.sh             # one-time CI bootstrap on a test Proxmox host
│   ├── generate-manifest.sh           # interactive manifest builder (humans)
│   └── destroy-all.sh
├── docs/
│   ├── README.md                      # docs index
│   ├── quickstart.md
│   ├── manifest-reference.md
│   ├── components/
│   │   ├── wazuh.md
│   │   ├── thehive-cortex.md
│   │   ├── misp.md
│   │   ├── zeek-suricata.md
│   │   ├── dashboards.md
│   │   └── mcp.md
│   ├── architecture.md                # merged from data-flow.md + overview.md, reduced
│   ├── gotchas.md                     # pruned to still-relevant
│   ├── adding-a-component.md          # was adding-a-stack.md, rewritten
│   ├── operations/
│   │   ├── upgrade.md
│   │   ├── destroy.md
│   │   └── troubleshooting.md
│   └── assets/soc-stack-banner.jpg
├── playbooks/                         # unchanged
├── cases/                             # unchanged
└── mcp-servers/
    └── README.md                      # updated: index to deployed-by-default servers
```

### Deleted

| Path | Why |
|---|---|
| `scripts/create-vm.ps1`, `destroy-vm.ps1`, `find-vm-ip.ps1` | Hyper-V path removed |
| `cloud-init/` | Hyper-V only |
| `reference/hyper-v/` | Hyper-V only |
| `proxmox/ct/thehive-cortex.sh`, `proxmox/ct/misp.sh` | Per-tool one-liners superseded by `install.sh --components <x>` |
| `proxmox/install/*.sh` | Superseded by `scripts/components/*/deploy.sh` |
| `proxmox/misc/soc-stack.func` | Absorbed into `scripts/lib/lxc.sh` |
| `specs/` | Hyper-V VM specs no longer needed; preset data moves to per-component `manifest.jsonc` |
| `stacks/opencti/.gitkeep` | OpenCTI deferred to v2 |
| `stacks/wazuh/.gitkeep`, `stacks/zeek-suricata/.gitkeep` | Merged into `scripts/components/<x>/deploy.sh` |
| `docs/architecture/data-flow.md` (410 lines) | Reduced and merged into `docs/architecture.md` |
| `docs/deployment/docker-compose.yml` | Misplaced; deleted (lives next to `components/thehive-cortex/` if still needed) |

### Moved (existing code preserved)

| From | To |
|---|---|
| `scripts/setup/install.sh` | `scripts/install.sh` (rewritten as orchestrator) |
| `scripts/setup/integrate.sh` | Split into `scripts/components/*/integrate.sh` |
| `scripts/setup/components/wazuh.sh` | `scripts/components/wazuh/deploy.sh` |
| `scripts/setup/components/thehive.sh` + `cortex.sh` | `scripts/components/thehive-cortex/deploy.sh` (merged) |
| `scripts/setup/components/misp.sh` | `scripts/components/misp/deploy.sh` |
| `scripts/setup/components/zeek.sh` + `suricata.sh` | `scripts/components/zeek-suricata/deploy.sh` (merged) |
| `scripts/setup/components/dashboards.sh` | `scripts/components/dashboards/deploy.sh` |
| `stacks/thehive-cortex/docker-compose.yml` + `setup.sh` | Folded into `scripts/components/thehive-cortex/` |
| `stacks/misp/*` | Folded into `scripts/components/misp/` |
| `docs/adding-a-stack.md` | `docs/adding-a-component.md` (rewritten) |

### Preserved as-is

- `playbooks/` (incident response content, not infrastructure)
- `cases/` (case studies)
- `LICENSE`, `.github/FUNDING.yml`
- `docs/assets/soc-stack-banner.jpg`

### New README pitch

> SOC Stack is a one-shot installer for a complete Security Operations Center on Proxmox VE. Run one command on your Proxmox host - or have an agent do it - and 30 minutes later you have Wazuh (SIEM), TheHive + Cortex (case management + SOAR), MISP (threat intel), Zeek + Suricata (NSM + IDS), custom dashboards, and 9 MCP servers wired up and talking to each other. Non-interactive by default. Idempotent. JSON output for agents. Built for replication.

Three quickstart blocks below it: human full-stack, human custom, agent (with sample output JSON).

## Known risks and open questions

1. **MCP server transport support.** The 9 servers may currently be stdio-only. If any are stdio-only, options are: patch each server to support SSE (preferred, upstream contribution), or wrap with `mcp-bridge` in the s3-mcp LXC (works but adds a layer). Implementation plan must verify each server's transport options before scoping the mcp deploy.sh.

2. **Wazuh inside LXC reliability.** Wazuh's official installer is designed for VMs, not LXCs. The current `components/wazuh.sh` works but indexer JVM tuning may need adjustment for LXC memory cgroups. Will validate during first integration test run.

3. **Test host resource ceiling.** A 32GB test host with ~10GB of pre-existing workloads leaves ~22GB free. Full-stack `--preset minimal` uses ~10GB peak, so it fits. Production preset (~40GB total) does not fit on a 32GB test host and is verified only by component-level minimal tests + manifest validation.

4. **GitHub Actions self-hosted runner security.** A self-hosted runner on a home network executes arbitrary code from PRs. Mitigations: runner only executes against forks of THIS repo (workflow guard); runner LXC is unprivileged with limited sudoers entries on the Proxmox host; VMID range 9000-9099 is reserved and the reaper enforces TTL.

5. **Idempotency markers in third-party configs.** Some integration `sed`-in-place edits use markers like `# soc-stack` to detect prior changes. If the upstream tool (TheHive, Wazuh) changes its config syntax, the marker scheme may miss. Mitigated by `verify.sh` running after `integrate.sh` and asserting the integration actually flows end-to-end.

## Out of scope for this design

- The actual implementation order, file-by-file changes, migration sequence (covered by the implementation plan that comes next)
- OpenCTI integration (v2)
- Public release / changelog / versioning policy (v1.0.0 ships at the end of this work; subsequent versioning is a separate decision)
- Documentation site beyond markdown in the repo
- Backup / restore / DR (handled separately by the user's existing restic flow)
