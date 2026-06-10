# Repository Guidance

## Definition of Done
Before reporting any code change as complete, run the single verification entrypoint and confirm it exits 0:

```bash
./scripts/verify
```

It runs the bats submodule init (if missing), the unit tests, the CI shellcheck invocation, and the CI manifest validation, all local and read-only against Proxmox.

For reference, the individual steps it runs in order:
1. `git submodule update --init` (once per clone; bats lives in `tests/vendor/`, tests will not start without it)
2. `./tests/unit/run.sh`
3. Shellcheck, exactly as CI (`.github/workflows/ci.yml`) runs it:
   `shellcheck --severity=warning install.sh scripts/install.sh scripts/lib/*.sh scripts/components/*/*.sh tests/integration/*.sh tools/*.sh`
4. Manifest validation, exactly as CI runs it:
   `for m in scripts/components/*/manifest.jsonc; do sed 's://.*$::g' "$m" | jq -e .name >/dev/null && sed 's://.*$::g' "$m" | jq -e .presets >/dev/null || echo "FAIL: $m"; done`

Report actual command output, not expectations. If anything fails, quote the failure verbatim and do not claim success. If a command cannot run (missing tool, no host), name the exact blocker instead of skipping it silently.

## Hard Prohibitions
- Never run `deploy.sh`, `integrate.sh`, `destroy.sh`, or the orchestrator without `--dry-run` against any real Proxmox host (hogwarts or anything else). These provision, rewire, or destroy live LXC containers on a host running production CTs. Only a live run explicitly requested by the user in this session is allowed. Default to `sudo bash install.sh --dry-run`.
- Never point `tests/integration/`, `destroy-test-env.sh`, or any per-component `destroy.sh` at a host running production CTs. They delete containers and state. They assume a dedicated test host.
- Never weaken the exit-code contract (0 success, 1 preflight, 2 validation, 3 component failed, 4 integration failed, 5 mixed state) or the idempotent state-file behavior (`/var/lib/soc-stack/state/<name>.json` is the source of truth; rerun skips deployed components, `--force` redeploys, integration failure must exit 4).
- Never print, log, copy, or commit real secret values. The installer generates and stores them (`/var/lib/soc-stack/secrets/`, 0600 root-only; bearer tokens in `/root/mcp-clients.json`). Keep redaction in `scripts/lib/secrets.sh` intact; `--include-secrets-json` is the only sanctioned bypass. Commit only `config.env.template` style files; `**/config.env` and `**/api-keys.txt` are gitignored on purpose.
- Never weaken, skip, comment out, or delete a failing test to get green. Fix the code or report the failure.
- Never push with `--no-verify`. This repo sets `core.hooksPath=hooks` and `hooks/pre-push` runs a secret scan; bypassing it is how secrets leak.
- Never work around a blocker (permissions, missing host, failing hook). Stop and report the exact error.

## Project Shape
- One-shot Proxmox VE installer for a full SOC: Wazuh, TheHive + Cortex, MISP, Zeek + Suricata, dashboards, and an MCP component exposing 9 SSE-wrapped MCP servers. Everything is bash plus declarative JSONC manifests.
- `install.sh` at the repo root is a thin wrapper for `curl | bash`. The real orchestrator is `scripts/install.sh`. Edit the orchestrator, not the wrapper, unless the wrapper itself is the target.
- Shared bash modules live in `scripts/lib/` (logging, secrets, json-out, idempotency, network, manifest, preflight, lxc). When changing one, run its unit tests in isolation: `tests/vendor/bats-core/bin/bats tests/unit/test_<module>.bats`.
- Each component is a folder under `scripts/components/<name>/` with a fixed interface: `manifest.jsonc`, `lxc-spec.sh`, `deploy.sh`, `verify.sh`, `integrate.sh`, `destroy.sh`. The orchestrator only talks through this interface. To add a component, add a folder with all six files; do not add component special cases to the orchestrator. Contract docs: `docs/adding-a-stack.md`; design spec: `docs/superpowers/specs/`.

## Working Rules
- Adding or changing a prompt in the installer: stdin is closed under `curl | sudo bash` and the installer auto-enables non-interactive mode, so every prompt must have a flag and a default. A local TTY run without `--components`/`--manifest` opens an interactive picker; preserve both paths.
- Changing deploy or recovery logic: re-running a failed install is the supported recovery path. Verify your change keeps reruns safe (state-file skip, `--force` redeploy, exit 4 on integration failure).
- Touching anything that deploys: check `docs/gotchas.md` first (sparse VHDX, cloud-init networking, and more). Scripts must handle everything listed there; an unhandled documented gotcha is a bug. If you hit a new one, add it.
- Capturing test output: `tests/unit/run.sh` switches the bats formatter to `tap` when stdout is not a TTY. Do not "fix" missing pretty output; the pretty formatter breaks under log capture.
- Validating installer behavior without a live host: unit tests use mocked Proxmox binaries; `--dry-run` is the only safe end-to-end check. There is no way to fully exercise deploy logic without a Proxmox host, so say so rather than pretending coverage exists.

## Memory Handoff
At the end of any substantial task, write a handoff note to `.claude/memory-handoffs/` using that directory's `TEMPLATE.md`. Record durable discoveries, gotchas, and decisions. Do not wait to be reminded.
