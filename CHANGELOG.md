# Changelog

All notable changes to soc-stack are documented in this file. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `tools/package-verify.sh`: read-only check that a file on a Debian or Ubuntu host (or Proxmox container, with an independent outside read) matches the file in its owning distro package; JSON or Markdown verdict with documented exit codes. See `docs/package-verify.md`. Trust model: `match` (exit 0) requires an independent outside hash of the caller-supplied canonical path; an inside-only result is `match-unverified` (exit 4, `trust: "self-reported"`). The .deb is checked against its own control fields and streamed (never extracted); directory-backed rootfs gets no outside read; Markdown output escapes target-controlled text.
- `tools/package-verify.sh` second review round: the outside view runs under `bash` with `pipefail` and accepts a hash only when the byte count equals the `debugfs stat` size (a failed read no longer passes as the empty-input hash); an inside hash mismatch is reported as `mismatch` even if the outside view later fails; usrmerge aliases (`/usr/bin` vs `/bin`) are resolved and reported as `dpkg_path`; download network failures and HTTP 5xx are `error` while 404 stays `package-unknown`; a dependency preflight exits 3; every decoder is bounded by `PV_DECODER_TIMEOUT` and `PV_DECODER_VMEM_KB`, control output is capped at 4 KiB and the member listing is streamed and stops after two matches.
- `tools/package-verify.sh` third review round (tool version 1.3.0): `dpkg-deb --fsys-tarfile` runs with `--threads-max=1` so large multi-block xz packages decode under the 1 GiB memory cap; the outside view hashes and counts bytes in a single `debugfs` read; a usrmerge alias is accepted only when `readlink -f` of the alias resolves to the canonical path, and a dpkg diversion on the alias is `package-unknown`; the tar listing is clipped per line and the filter emits only bounded fields (name 512 bytes, link target 256 bytes) under its own timeout and memory cap; `PV_DECODER_TIMEOUT` (1..3600) and `PV_DECODER_VMEM_KB` (262144..8388608) are range-checked with exit 3, and a memory cap that cannot be applied is an error.
- `tools/package-verify.sh` 1.4.0: independent archive signature check. After the .deb SHA-256 equals the target's apt SHA256, the runner verifies the archive's `InRelease` with `gpgv` (apt's rule: at least one valid signature, none bad, expired or revoked; unknown-key signatures tolerated), checks the signed `Packages.xz` hash and size and `Valid-Until`, and requires the signed stanza's SHA256 and Filename to equal the target's. JSON `archive_signature` is now `verified`, `not-verified` or `failed`, with `archive_signature_detail` (suite, component, index, signer fingerprints, reason). A failed check is an `error` (exit 3) but never overrides an established `mismatch`. New `--keyring <path>` and `--no-archive-check`; `gpgv`, `xz` and the keyring are optional runner requirements (missing means `not-verified`, never an error). 21 new bats tests use a throwaway signing key.
- ATT&CK Navigator coverage layer export: `scripts/lib/navigator.sh` + declarative map in `scripts/lib/data/attack-coverage.json`, written after install to `--navigator-out` (default `/root/soc-stack-navigator.json`); offline regenerator `tools/export-navigator-layer.sh`. Only deployed components and successfully integrated links contribute techniques.
- `docs/archive/operations/operator-report-2026-06.md` and `operator-report-reconciliation-2026-08.md` (close stale June operator-center snapshot; [#18](https://github.com/lidless-labs/soc-stack/issues/18))
- README adoption pass: prominent website link, live CI and release badges, a keyword-rich "What it does" section, a redacted result-JSON example block, and "Why not something else?" / "What soc-stack is not" sections
- `CODE_OF_CONDUCT.md` (Contributor Covenant 2.1)
- `.github/ISSUE_TEMPLATE/config.yml` (disables blank issues, routes security reports and questions off the issue tracker)
- No-PII / no-secret-leak checkbox in the pull request template
- TTY component picker when run locally without `--components`/`--manifest`
- `--include-secrets-json` (result JSON redacts credentials by default) and `--mcp-bind-host` (MCP SSE binds 127.0.0.1 by default)
- `SECURITY.md` documenting the threat model and hardening posture
- `docs/adding-a-component.md` (replaces the stale `docs/adding-a-stack.md`)
- Bats coverage for the exit-code contract, integration state tracking, and IP allocation bounds (105 unit tests)

### Fixed
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
