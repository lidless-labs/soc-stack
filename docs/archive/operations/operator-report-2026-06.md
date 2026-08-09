# Operator Report (June 2026 snapshot)

- **Report id:** `20260610-operator-report` (reconstructed)
- **Target:** `soc-stack` (lidless-labs/soc-stack)
- **Generated:** circa 2026-06-10 (local operator-center; never committed to git)
- **Git (when filed):** pre-OSS-adoption `main`, shortly after v1.0.0 (2026-05-16)
- **Status:** **Closed.** Superseded by [operator-report-reconciliation-2026-08.md](operator-report-reconciliation-2026-08.md) ([#18](https://github.com/lidless-labs/soc-stack/issues/18)).

This file reconstructs the open June operator report that Brigade work briefs kept surfacing. The original bundle lived only under `.brigade/center/reports/` on the maintainer machine. It was not in the public git history.

## Why this report existed

The [2026-05-15 unification design spec](../../design/specs/2026-05-15-soc-stack-unification-design.md) described a target docs tree and a single `install.sh` path. v1.0.0 shipped the component model, but several spec files and OSS maintainer-health docs were still missing. The operator-center snapshot captured that drift so it would not hide behind newer work.

## Review queue (as of June 2026)

Severity uses operator-center labels: `fail` = blocking gap in repo health, `warn` = incomplete or deferred.

| Id | Severity | Finding |
|---|---|---|
| `docs_adding_a_component` | fail | `docs/adding-a-component.md` missing; `docs/adding-a-stack.md` stale or absent |
| `docs_operations_ci` | warn | `docs/operations/ci.md` missing (self-hosted runner bootstrap undocumented) |
| `security_md` | fail | `SECURITY.md` missing |
| `oss_maintainer_health` | warn | `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, issue/PR templates incomplete vs OSS adoption standard |
| `docs_components_partial` | warn | Only some `docs/components/*.md` pages exist (thehive-cortex, misp expected; wazuh, dashboards, zeek-suricata, mcp missing) |
| `docs_quickstart` | warn | `docs/quickstart.md` missing (design spec target tree) |
| `docs_manifest_reference` | warn | `docs/manifest-reference.md` missing (`--manifest` mode undocumented in standalone doc) |
| `docs_operations_runbooks` | warn | `docs/operations/{upgrade,destroy,troubleshooting}.md` missing |
| `docs_architecture_merged` | warn | Merged `docs/architecture.md` missing; split `overview.md` + `data-flow.md` remain |
| `legacy_scripts_setup` | warn | `scripts/setup/` still present alongside `scripts/install.sh` orchestrator |
| `legacy_paths_removed` | warn | Verify `proxmox/`, `stacks/`, Hyper-V scripts fully removed from tree |
| `verify_entrypoint` | warn | No single `./scripts/verify` (or equivalent) CI parity entrypoint |
| `mcp_supply_chain` | warn | MCP server clones may track moving `origin/HEAD` instead of pinned SHAs |
| `credential_rotation_verify` | warn | Default-credential rotation not verified before `status: deployed` |
| `content_guard_hook` | warn | No content-guard-backed `hooks/pre-push` on tracked files |
| `org_urls_stale` | warn | Clone/install/badge URLs still point at `solomonneas/*` after lidless-labs org cutover |
| `design_spec_stale` | warn | Design spec "Context" still describes pre-unification README and removed paths as current |

## Suggested commands (June 2026)

- `brigade center report build --target .` (regenerate local snapshot)
- `./scripts/verify` (once verify entrypoint exists)
- `brigade guard git --all-tracked` (content-guard / publish policy)

## Boundaries

- Local operator report only; no automatic promotion to git.
- Findings above are frozen at the June filing date; do not treat this queue as current work.
