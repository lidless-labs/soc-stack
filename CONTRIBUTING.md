# Contributing to soc-stack

Thanks for your interest. soc-stack is a one-shot Proxmox installer for a complete Security Operations Center. Each tool (Wazuh, TheHive+Cortex, MISP, Zeek+Suricata, custom dashboards, MCP servers) is a self-contained "component" in `scripts/components/<name>/`.

## Adding a new component

A component is six files in `scripts/components/<name>/`. The orchestrator (`scripts/install.sh`) only talks to components through this fixed interface.

| File | Runs where | Purpose |
|---|---|---|
| `manifest.jsonc` | (declarative) | Component metadata: presets, ports, dependencies, what it provides |
| `lxc-spec.sh` | Proxmox host | Emits `pct create` flags (one per line) based on `${SOC_PRESET}` |
| `deploy.sh` | inside the LXC | Idempotent installer; writes `${SOC_STATE_DIR}/state/<name>.json` |
| `verify.sh` | inside the LXC | Health check; exit 0 if healthy |
| `integrate.sh` | Proxmox host | Wires this component to its peers (reads peer state files) |
| `destroy.sh` | Proxmox host | Tears down the LXC + state file |

### manifest.jsonc

```jsonc
{
  "name": "your-component",
  "display_name": "Your Tool",
  "description": "One-line description of what this component does",
  "depends_on": [],           // hard deps - orchestrator skips if a dep is missing
  "provides": ["your_url"],   // what state keys this component exposes
  "presets": {
    "minimal":    { "ram_mb": 2048, "disk_gb": 20, "cores": 1 },
    "standard":   { "ram_mb": 4096, "disk_gb": 40, "cores": 2 },
    "production": { "ram_mb": 8192, "disk_gb": 80, "cores": 4 }
  },
  "ports": [80, 443],
  "template_pattern": "ubuntu-22.04-standard",
  "features": ["nesting=1"],
  "unprivileged": true,
  "install_method": "native"    // or "docker-compose"
}
```

### deploy.sh

Runs inside the LXC. Receives via env:
- `SOC_STATE_DIR`: where to write state (typically `/var/lib/soc-stack`; pulled back to host by orchestrator)
- `SOC_COMPONENT`: your component's name
- `SOC_PRESET`: minimal | standard | production
- `SOC_NON_INTERACTIVE`: always "1" in agent-driven runs

Required:
1. **Idempotent**. Check service state first; if already running, refresh state and exit 0.
2. **Writes state JSON** on success at `${SOC_STATE_DIR}/state/<name>.json`:
   ```json
   {
     "component": "your-component",
     "status": "deployed",
     "url": "http://...",
     "credentials": { "user": "...", "password": "..." },
     "services": ["systemd-unit-1", "systemd-unit-2"]
   }
   ```
3. **Writes failed state** on error (via an ERR trap or explicit `write_failed` helper):
   ```json
   { "component": "your-component", "status": "failed", "error": "..." }
   ```

### integrate.sh

Runs on the Proxmox host after all deploys. Read peer state files from `${SOC_STATE_DIR}/state/<peer>.json`. If a peer is missing or `status != "deployed"`, log a warning and exit 0 (don't fail the integration phase).

Use `pct push` + `pct exec` to push config into your LXC. Idempotency: grep for a marker before applying changes.

### Idempotency rules

- Every step checks "is this already done?" before doing it. No try-then-undo.
- State files in `${SOC_STATE_DIR}/state/<name>.json` are the source of truth.
- `--force` is the only way to redeploy a completed component.

## Tests

Two layers run on every PR:

1. **Bats unit tests** (`tests/unit/*.bats`). Use mocked `pct`/`qm`/`docker` binaries from `tests/unit/fixtures/bin/`. Each new lib function gets a failing test first, then implementation. See existing tests for the pattern.

2. **Integration tests** (`tests/integration/assert-*.sh`). Run on a self-hosted runner against a real Proxmox host. Each component must have its own `assert-<name>.sh` that:
   - Confirms `status == "deployed"` in the result JSON
   - Confirms the component's HTTP endpoints respond
   - Confirms credentials are populated

## Branch + PR flow

- Branch off `main` as `feat/<short-name>` or `fix/<short-name>`
- One commit per logical change
- Conventional commit messages: `feat(component): ...`, `fix(lib): ...`, `docs: ...`, `test: ...`, `ci: ...`
- No `Co-Authored-By: Claude` trailers
- No em-dashes in code or commit messages
- All shellcheck-clean

Open a PR; CI runs shellcheck + bats + manifest-schema (GitHub-hosted) plus per-component integration (proxmox-host). Merge to main triggers full-stack integration.

## License

By contributing, you agree your contributions are licensed under MIT.
