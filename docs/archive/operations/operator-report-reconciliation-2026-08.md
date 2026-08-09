# Operator report reconciliation (August 2026)

- **Closes:** [#18 — review and close the stale June operator report](https://github.com/lidless-labs/soc-stack/issues/18)
- **June report:** [operator-report-2026-06.md](operator-report-2026-06.md) (reconstructed snapshot)
- **Verified against:** `origin/main` at `8696818519f277b5ff7835f085e931329512f6f7` (`8696818`)
- **Fresh operator-center snapshot:** 9 review warnings + 1 `fail` (local Brigade state only) at `20260809-025405-operator-report-58cb17`
- **Verification receipt:** `./scripts/verify` (105 unit tests, exit 0)

## Disposition taxonomy

| Disposition | Meaning |
|---|---|
| **resolved** | Finding was valid in June; fixed on `main` at `8696818` |
| **superseded** | Finding replaced by a different doc, path, or workflow |
| **still_open** | Gap remains on `8696818`; track as follow-up |
| **accepted** | Intentional example, local-only tooling, or documented risk |
| **out_of_scope** | Brigade dogfood or unrelated to soc-stack product surface |

## Findings

| June id | Disposition | Notes (verified at `8696818`) |
|---|---|---|
| `docs_adding_a_component` | **resolved** | `docs/adding-a-component.md` exists; `docs/adding-a-stack.md` removed |
| `docs_operations_ci` | **resolved** | `docs/operations/ci.md` documents self-hosted runner setup |
| `security_md` | **resolved** | `SECURITY.md` documents threat model and hardening |
| `oss_maintainer_health` | **resolved** | `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `.github/ISSUE_TEMPLATE/*`, PR template present |
| `docs_components_partial` | **still_open** | `docs/components/misp.md` and `thehive-cortex.md` exist; `wazuh.md`, `dashboards.md`, `zeek-suricata.md`, `mcp.md` still missing |
| `docs_quickstart` | **superseded** | Install/quickstart content lives in README (`Install`, `Flag reference`, `Operations`) |
| `docs_manifest_reference` | **still_open** | No standalone `docs/manifest-reference.md`; schema remains in design spec + `--manifest` tests |
| `docs_operations_runbooks` | **superseded** | Upgrade/destroy/teardown guidance is in README `Operations` (re-run, `destroy.sh`, full teardown) |
| `docs_architecture_merged` | **still_open** | `docs/architecture/overview.md` + `data-flow.md` remain; merged `docs/architecture.md` not written |
| `legacy_scripts_setup` | **still_open** | `scripts/setup/install.sh` and `scripts/setup/components/*` still in tree (orchestrator is `scripts/install.sh`) |
| `legacy_paths_removed` | **resolved** | `proxmox/`, `stacks/`, Hyper-V scripts removed per v1.0.0 changelog |
| `verify_entrypoint` | **resolved** | `./scripts/verify` runs bats, shellcheck, and manifest validation |
| `mcp_supply_chain` | **resolved** | `scripts/components/mcp/deploy.sh` pins MCP clones to commit SHAs |
| `credential_rotation_verify` | **resolved** | TheHive/MISP deploy paths verify rotation before reporting deployed |
| `content_guard_hook` | **resolved** | `hooks/pre-push` scans tracked files with content-guard `public-repo` policy |
| `org_urls_stale` | **still_open** | README/install curl URLs and several docs still use `solomonneas/*`; badges use `lidless-labs` |
| `design_spec_stale` | **superseded** | Spec is historical; status annotated and archive linked (see design spec header) |

## August 2026 operator-center snapshot (local only)

Built with `BRIGADE_EXTRAS=1 brigade center report build` on a fresh cloud workspace. These items are **not** soc-stack product defects; they reflect uninitialized local Brigade operator state:

| Subsystem | Severity | Summary |
|---|---|---|
| `security` | fail | No `.brigade/security/latest` evidence bundle |
| `backup` | warn | Missing `.brigade/backups/nas-summary.json` |
| `memory-care` | warn | Missing memory-care scan artifacts |
| `project-consolidation` | warn | Missing `.brigade/projects.toml` |
| `repo-fleet` | warn | No local fleet report/sweep/release train |
| `context` | warn | No context packs |
| `center-readiness` | warn | No operator readiness closeout receipt |
| `roadmap` | warn | No `ROADMAP.md` / `docs/command-inventory.md` (Brigade dogfood; **out_of_scope** for soc-stack) |
| `template_privacy` | warn | `docs/operations/ci.md:50` documents `/home/runner/actions-runner` (**accepted** runner layout example) |

Disposition for the June report: **superseded** and **archived**. Work briefs should cite this reconciliation instead of the June queue.

## Regenerate local operator reports

```bash
pipx install brigade-cli   # or: pip install brigade-cli
export PATH="$HOME/.local/bin:$PATH"
BRIGADE_EXTRAS=1 brigade center report build --target .
BRIGADE_EXTRAS=1 brigade center report list --target .
```

Archive a local bundle into gitignored storage:

```bash
BRIGADE_EXTRAS=1 brigade center report archive --target . <report-id>
```

Tracked historical reports live under `docs/archive/operations/` only after an explicit docs pass (this issue).
