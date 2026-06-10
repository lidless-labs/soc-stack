# Adding a Component

Every component is a self-contained folder under `scripts/components/<name>/`. The orchestrator (`scripts/install.sh`) only talks to components through a fixed six-file interface; adding a component means dropping in a folder, with no orchestrator changes.

## The contract

```
scripts/components/<name>/
├── manifest.jsonc      # declarative: presets, ports, deps, provides
├── lxc-spec.sh         # host: emits pct create flags for the preset
├── deploy.sh           # inside LXC: idempotent installer, writes state JSON
├── verify.sh           # inside LXC: health check, exit 0 if healthy
├── integrate.sh        # host: wires this component to peers via their state
└── destroy.sh          # host: tears down the LXC and state
```

## manifest.jsonc

Declares what the component is and needs. Example (MISP):

```jsonc
{
  "name": "misp",
  "display_name": "MISP",
  "description": "Threat Intelligence Sharing Platform (MariaDB + Redis backed)",
  "depends_on": [],
  "provides": ["misp_url", "misp_api_key"],
  "presets": {
    "minimal":    { "ram_mb": 2048, "disk_gb": 20, "cores": 1 },
    "standard":   { "ram_mb": 4096, "disk_gb": 40, "cores": 2 },
    "production": { "ram_mb": 8192, "disk_gb": 80, "cores": 4 }
  },
  "ports": [443],
  "template_pattern": "ubuntu-22.04-standard",
  "features": ["nesting=1"],
  "unprivileged": true,
  "install_method": "docker-compose",
  "default_creds": { "user": "admin@admin.test", "rotate_on_install": true }
}
```

`depends_on` drives deploy ordering warnings; `provides` documents what peer state keys other components can consume.

## lxc-spec.sh (runs on the Proxmox host)

Reads `SOC_PRESET`, `SOC_NETWORK_CONFIG`, `SOC_STORAGE` from the environment and prints one `pct create` flag per line:

```
--memory 4096
--cores 2
--rootfs local-lvm:40
--net0 name=eth0,bridge=vmbr0,ip=dhcp
--unprivileged 1
--features nesting=1
--onboot 1
--start 0
```

## deploy.sh (runs inside the LXC)

The orchestrator pushes this script into the freshly created LXC and runs it with:

- `SOC_STATE_DIR` - state root (default `/var/lib/soc-stack`)
- `SOC_COMPONENT` - the component name
- `SOC_PRESET` - minimal | standard | production
- `SOC_NON_INTERACTIVE=1`

Rules:

1. **Idempotent.** Check whether the service is already running and healthy first; if so, refresh the state file and exit 0. Never report `status: "deployed"` with missing credentials.
2. **Write state.** Finish by writing `${SOC_STATE_DIR}/state/<name>.json` with at least `component`, `status` (`deployed` or `failed`), service URLs, and credential fields. On failure write `status: "failed"` plus an `error` string and exit non-zero (use an ERR trap).
3. **Rotate default credentials and verify the rotation** before reporting deployed. Persist generated secrets to `${SOC_STATE_DIR}/secrets/<name>-*.txt` (mode 0600) *before* rotating so a mid-rotation crash is recoverable on re-run.
4. **Pin what you download.** Pin versions, tags, or commit SHAs for anything fetched at deploy time.

The orchestrator pulls the state file and secret files back to the host after deploy.

## verify.sh (runs inside the LXC)

Exit 0 when the component is genuinely usable (services active, API answering), non-zero otherwise. The orchestrator retries 3 times with 30s gaps before marking the component failed.

## integrate.sh (runs on the Proxmox host)

Reads peer state files from `${SOC_STATE_DIR}/state/*.json` and wires the component to its peers. Rules:

- Exit 0 silently when a peer is absent or not deployed; only wire what exists.
- Be idempotent (grep for a marker before appending to configs, check for existing webhooks before creating).
- A non-zero exit marks `integration.status: "failed"` in state and drives exit code 4/5 of the orchestrator.

## destroy.sh (runs on the Proxmox host)

Finds the VMID from the state file, stops and destroys the LXC, and removes the state file. Must be safe to run when nothing exists.

## Checklist

1. Create the folder and all six files (`chmod +x` the scripts).
2. Add the component name to `COMPONENTS_KNOWN` in `scripts/install.sh`.
3. shellcheck clean; add bats tests for any new lib behavior.
4. Add an integration assertion under `tests/integration/assert-<name>.sh`.
5. Document the component under `docs/components/<name>.md` and add it to the README components table.

The full design rationale lives in [docs/design/specs/2026-05-15-soc-stack-unification-design.md](design/specs/2026-05-15-soc-stack-unification-design.md).
