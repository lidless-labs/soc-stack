# Roadmap archive

Completed milestones, merged adoption work, and deliberately abandoned paths.
The live backlog is in [ROADMAP.md](../ROADMAP.md); GitHub issues remain the
source of truth for filed work.

## Shipped

### v1.0.0 (2026-05-16)

Initial stable release. All six components deploy end-to-end at `--preset minimal`
on Proxmox VE 7.x / 8.x / 9.x, with five cross-component integrations wired
automatically. See [CHANGELOG.md](../CHANGELOG.md#100---2026-05-16) for the full
release note.

- Six components: wazuh, thehive-cortex, misp, zeek-suricata, dashboards, mcp
- Five integrations: Wazuh → TheHive, TheHive ↔ Cortex, MISP → Suricata, Zeek → Wazuh, MCP → all peers
- Self-hosted CI runner on Proxmox with per-component integration matrix and full-stack merge gate
- Orchestrator with flags, manifest mode, idempotent state files, and structured JSON output

### Post-release adoption and hardening

- [PR #1](https://github.com/lidless-labs/soc-stack/pull/1) OSS adoption upgrade (README, CONTRIBUTING, issue templates)
- [PR #2](https://github.com/lidless-labs/soc-stack/pull/2) README badges switched to shieldcn
- [PR #3](https://github.com/lidless-labs/soc-stack/pull/3) CI skipped on docs-only changes
- [PR #4](https://github.com/lidless-labs/soc-stack/pull/4) soc-stack host integrations gated in CI
- [PR #6](https://github.com/lidless-labs/soc-stack/pull/6) Lidless owl mark and fleet footer

### Major v1 capabilities already in the tree

Capabilities shipped before or alongside v1.0.0 that are not tracked as separate
issues:

- One-shot `install.sh` orchestrator with `--components`, `--preset`, `--manifest`, `--dry-run`, and `--force`
- TTY component picker for local runs without `--components` / `--manifest`
- Result JSON with default credential redaction (`--include-secrets-json` bypass)
- MCP SSE bind host flag (`--mcp-bind-host`, defaults to localhost)
- Exit-code contract for integration failures (exit 4 / 5) with per-component integration state
- Pinned MCP server clones at commit SHAs
- Per-install MISP database password generation (replaced hardcoded compose values)
- systemd hardening for MCP servers and dashboards
- [SECURITY.md](../SECURITY.md) threat model and hardening posture
- [docs/adding-a-component.md](adding-a-component.md) component contract guide

## Abandoned

Paths explicitly removed or deferred. Do not resurrect without a new GitHub issue:

- **OpenCTI** — deferred to v2; stub directory deleted (design spec non-goal)
- **Hyper-V deployment** — `scripts/create-vm.ps1`, cloud-init, and Hyper-V VM specs removed at unification
- **Per-tool Proxmox one-liners** — `proxmox/ct/*.sh` superseded by `install.sh --components <name>`
- **Legacy unified installer** — `scripts/setup/install.sh` narrative superseded by `scripts/install.sh`
- **Docker Compose as primary install path** — compose definitions inlined into per-component `deploy.sh` inside LXCs

## Superseded documentation

Material that predates Proxmox-only unification and is queued for cleanup in the
live backlog:

- Hyper-V and cloud-init recovery notes still present in [gotchas.md](gotchas.md) — tracked as [#19](https://github.com/lidless-labs/soc-stack/issues/19)
