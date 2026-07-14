# Changelog

All notable changes to soc-stack are documented in this file. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- README adoption pass: prominent website link, live CI and release badges, a keyword-rich "What it does" section, a redacted result-JSON example block, and "Why not something else?" / "What soc-stack is not" sections
- `CODE_OF_CONDUCT.md` (Contributor Covenant 2.1)
- `.github/ISSUE_TEMPLATE/config.yml` (disables blank issues, routes security reports and questions off the issue tracker)
- No-PII / no-secret-leak checkbox in the pull request template
- TTY component picker when run locally without `--components`/`--manifest`
- `--include-secrets-json` (result JSON redacts credentials by default) and `--mcp-bind-host` (MCP SSE binds 127.0.0.1 by default)
- `SECURITY.md` documenting the threat model and hardening posture
- `docs/adding-a-component.md` (replaces the stale `docs/adding-a-stack.md`)
- Bats coverage for the exit-code contract, integration state tracking, and IP allocation bounds, plus the hardening pass (state-file safety, redaction, static/VLAN networking, flag parsing, MCP exposure warning): 123 unit tests
- `--gateway` flag to set the default route for static-mode containers

### Security
- MCP SSE endpoints now enforce their bearer token. `mcp-proxy` has no auth of its own, so each endpoint is fronted by an nginx gateway that returns `401` unless the `Authorization` header is the exact per-server token; `mcp-proxy` binds loopback behind it. Previously the token was advertised to clients but never enforced
- Credentials are no longer passed on a process command line during provisioning (`/proc/<pid>/cmdline` exposure): the LXC root password is set via `chpasswd` over stdin, and the TheHive/Cortex admin-credential API calls use `curl --data @-`
- CI: the self-hosted Proxmox integration jobs are gated to same-repo PRs and pushes so fork-PR code cannot run as root on the host; `actions/checkout` pinned to a commit SHA; workflow runs with `permissions: contents: read`
- Result-JSON redaction broadened to more key names (`pwd`, `passwd`, `bearer`, `credential`, `private_key`) and to credentials embedded in URL values
- Cortex admin password hash uses a full-length random salt (was a 24-bit, fixed-prefix salt)
- MCP integration parses `rapid7.env`/`sophos.env` as data instead of sourcing them as shell
- The installer warns (in logs and the result JSON) when MCP binds a non-loopback host

### Removed
- Dead legacy installer tree `scripts/setup/**` (superseded by the `scripts/install.sh` orchestrator and `scripts/components/*`). It was excluded from the shellcheck gate and carried `verify=False` TLS-off alert forwarding, a MISP installer fetched from a mutable branch and run as root, cleartext password printing, and an allow-all firewall

### Fixed
- `gen_password` returned exit 141 on success under `set -o pipefail` (SIGPIPE from `tr`), a latent abort for any `set -e` caller
- `state_set` overwrote a good state file with empty content when `jq` failed (only replaces on success now); corrupt state files are tolerated instead of aborting the run, and the temp file is written in the target directory for an atomic rename
- `--ip-mode static` now sets a default route (new `--gateway` flag, else the first host of the range); static containers previously came up with no route and failed the network wait
- `--vlan` is now applied to the container network config; it was validated and stored but never took effect
- Static IPs are allocated by the component's canonical ordinal, so component subsets and re-runs no longer collide on the same address
- A successful deploy records `status=deployed` authoritatively, so it is not re-deployed on every re-run when the in-LXC state file did not survive the pull
- `--flag=value` argument form is accepted (was rejected as an unknown flag)
- `validate_manifest` exact-matches component names (`grep -qw` had accepted `cortex` and treated names as regexes)
- Exit-code contract: integration failures now produce exit 4/5 as documented; `integration.status` is tracked per component
- `allocate_ip` bounds-checks the last octet instead of emitting invalid addresses
- TheHive/MISP default-credential rotation is verified before a component reports deployed; idempotent re-runs refuse to report deployed with missing credentials
- MCP env files are rebuilt without passing credentials through sed; secrets written under `umask 0077`
- README operations example used an unsupported `--no-integrate=false` flag form

### Changed
- MCP server repos are cloned at pinned commit SHAs instead of tracking `origin/HEAD`
- MISP database passwords are generated per install (were hardcoded compose values)
- systemd units for MCP servers and dashboards run with hardening directives
- Design docs moved from `docs/superpowers/` to `docs/design/`; the result-JSON spec is now tracked in the repo

## [1.0.0] - 2026-05-16

Initial stable release. All 6 components deploy end-to-end at `--preset minimal` on Proxmox VE 7.x / 8.x / 9.x, with 5 cross-component integrations wired automatically. CI runs on every PR.

### Added
- 6 components: wazuh, thehive-cortex, misp, zeek-suricata, dashboards, mcp
- 5 cross-component integrations: Wazuh -> TheHive webhook, TheHive <-> Cortex, MISP -> Suricata rule feed, Zeek -> Wazuh agent, MCP -> all peers
- Self-hosted CI runner on Proxmox host with scoped sudoer, test reaper cron
- `.github/workflows/ci.yml`: shellcheck + bats + manifest-schema + per-component integration matrix + full-stack on merge
- `tools/setup-ci-runner.sh`: one-shot bootstrap for the CI infrastructure
- `tools/soc-stack-test-reaper.sh`: destroys test LXCs (VMID 9000-9099) older than 90 minutes
- `CONTRIBUTING.md`, `CHANGELOG.md`, `.github/PULL_REQUEST_TEMPLATE.md`, `.github/ISSUE_TEMPLATE/{bug_report,component_request}.md`
- `docs/operations/ci.md`, `docs/components/{thehive-cortex,misp}.md`

### Changed
- `lxc_wait_network`: default timeout 180s -> 240s, with a 30s grace probe at the end
- `assert-mcp.sh`: 60s grace period for `mcp-proxy` to bind ports
- README rewritten for the unified `install.sh` entrypoint; legacy paths section removed

### Removed
- `cloud-init/`, `reference/hyper-v/`, `scripts/{create,destroy,find}-vm.ps1` (Hyper-V path)
- `proxmox/ct/`, `proxmox/install/`, `proxmox/misc/` (per-tool one-liners)
- `specs/` (Hyper-V VM specs, replaced by per-component `manifest.jsonc`)
- `stacks/` (docker-compose definitions inlined into `scripts/components/<name>/deploy.sh`)

## [0.9.0] - 2026-05-16

All 6 components deploy and assert green on Proxmox VE. 5/5 cross-component integrations wire correctly. Bridged the gap between Plan 1's wazuh-only proof and a full SOC stack.

### Added
- `scripts/components/{thehive-cortex,misp,zeek-suricata,dashboards,mcp}/`
- `tests/integration/assert-{thehive-cortex,misp,zeek-suricata,dashboards,mcp,all-integrations}.sh`
- `--manifest <path>` mode in `install.sh`: build manifest from JSON instead of CLI flags; flags can override manifest fields
- `lib/json-out.sh: emit_mcp_config`: paste-ready MCP client config emitter, wired to `--mcp-config-out`
- `lib(preflight): bootstrap_deps`: auto-install jq/curl/wget/openssl on fresh Proxmox hosts
- `mcp-proxy` (Python) inside the MCP LXC: bridges the 9 stdio MCP servers to SSE endpoints

### Changed
- `wazuh-install.sh -i` flag is preset-gated (only minimal needs it)
- `wazuh/integrate.sh`: full implementation (was a Plan 1 stub)
- `lxc_wait_network` default: 60s -> 180s
- Various fixes across all 5 new components (23 distinct bugs caught and fixed during smoke testing on the staging Proxmox host)

## [0.5.0] - 2026-05-15

Foundation. Wazuh deployable end-to-end via the unified orchestrator.

### Added
- `scripts/install.sh`: orchestrator with `--components`, `--preset`, `--bridge`, `--storage`, `--ip-mode`, `--vmid-start`, `--state-dir`, `--json-out`, `--mcp-config-out`, `--log-file`, `--dry-run`, `--force`, `--no-integrate`, `--non-interactive`, `--version`
- `scripts/lib/`: 8 shared modules (logging, secrets, json-out, idempotency, network, manifest, preflight, lxc) with 78 bats unit tests
- `scripts/components/wazuh/`: canonical component module (6 files)
- `tests/unit/`: bats-core 1.11.0 vendored, mocked Proxmox binaries
- `tests/integration/{setup,destroy}-test-env.sh`, `assert-wazuh.sh`
- `install.sh` at repo root: wrapper for `curl | sudo bash` invocation
- `docs/design/specs/2026-05-15-soc-stack-unification-design.md`: full design spec
- `docs/design/plans/2026-05-15-soc-stack-foundations-plan-1.md`: 31-task plan

## [0.1.0] - 2026-04-29

Pre-unification baseline. Per-tool LXC scripts and Hyper-V VM automation for TheHive+Cortex and MISP.

[1.0.0]: https://github.com/solomonneas/soc-stack/releases/tag/v1.0.0
[0.9.0]: https://github.com/solomonneas/soc-stack/releases/tag/v0.9.0
[0.5.0]: https://github.com/solomonneas/soc-stack/releases/tag/v0.5.0
[0.1.0]: https://github.com/solomonneas/soc-stack/releases/tag/v0.1.0
