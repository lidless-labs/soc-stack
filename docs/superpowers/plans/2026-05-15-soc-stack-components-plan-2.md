# SOC Stack Components Implementation Plan (2 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply Plan 1's component contract to the remaining 5 components (thehive-cortex, misp, zeek-suricata, dashboards, mcp), wire real cross-component integrations, finish the orchestrator surface (manifest mode + mcp-config emission + preset-gated wazuh -i flag), and ship v0.9.0 with all SOC tools deployable end-to-end.

**Architecture:** Each new component follows the wazuh pattern from Plan 1: `scripts/components/<name>/{manifest.jsonc, lxc-spec.sh, deploy.sh, verify.sh, integrate.sh, destroy.sh}`. Existing assets in `stacks/<name>/` and `scripts/setup/components/<name>.sh` are migrated into the new pattern (not deleted yet - legacy deletion is Plan 3). Cross-component wiring lives in each component's `integrate.sh` (read peer state, configure outbound webhooks/API connections).

**Tech Stack:** Bash 5+, jq, bats-core (vendored), Docker Compose v2, Proxmox `pct`/`qm`, MCP SSE transport (HTTP).

**Spec reference:** [`docs/superpowers/specs/2026-05-15-soc-stack-unification-design.md`](../specs/2026-05-15-soc-stack-unification-design.md)

**Prior plan:** [Plan 1 foundations](./2026-05-15-soc-stack-foundations-plan-1.md)

---

## Scope of this plan

**In:**
- 5 new component modules (thehive-cortex, misp, zeek-suricata, dashboards, mcp)
- Cross-component integration scripts:
  - Wazuh -> TheHive webhook
  - TheHive <-> Cortex API connection
  - MISP -> Suricata rule feed
  - Zeek -> Wazuh agent forward
  - MCP -> populated with all 9 servers connected to peer endpoints
- Orchestrator plumbing:
  - `emit_mcp_config()` in `lib/json-out.sh`, wired to `--mcp-config-out`
  - Manifest mode (`--manifest <path>`)
  - Preset-gated `wazuh-install.sh -i` flag (only minimal preset)
- 5 new integration assertion scripts (one per new component) + an `assert-all-integrations.sh` orchestrator
- proxmox-host smoke test: full stack at `--preset minimal`, assert all 5 cross-component integrations flow
- v0.9.0 tag at the end

**Out (defer to Plan 3):**
- Legacy path deletion (`stacks/`, `scripts/setup/`, `proxmox/ct/`, Hyper-V scripts, old specs) - left in place; only the new `scripts/components/` is authoritative
- Self-hosted GitHub Actions runner setup
- README rewrite (only a Plan 2 status note added)
- CONTRIBUTING/CHANGELOG/issue templates
- OpenCTI
- v1.0.0 release

---

## File structure

### New per-component folders (each gets 6 files, matching wazuh)

```
scripts/components/thehive-cortex/
  manifest.jsonc, lxc-spec.sh, deploy.sh, verify.sh, integrate.sh, destroy.sh
scripts/components/misp/
  ...
scripts/components/zeek-suricata/
  ...
scripts/components/dashboards/
  ...
scripts/components/mcp/
  manifest.jsonc, lxc-spec.sh, deploy.sh, verify.sh, integrate.sh, destroy.sh
  + mcp-servers/             # 9 systemd unit templates
```

### Orchestrator + lib changes

```
scripts/lib/json-out.sh                       # add emit_mcp_config
scripts/install.sh                            # wire --mcp-config-out, --manifest mode
scripts/components/wazuh/deploy.sh            # preset-gate -i flag
```

### New tests

```
tests/unit/test_mcp_config_emit.bats          # emit_mcp_config tests
tests/unit/test_orchestrator_manifest_mode.bats  # --manifest flag tests
tests/integration/assert-thehive-cortex.sh
tests/integration/assert-misp.sh
tests/integration/assert-zeek-suricata.sh
tests/integration/assert-dashboards.sh
tests/integration/assert-mcp.sh
tests/integration/assert-all-integrations.sh
```

### Migration references

Each component's `deploy.sh` migrates code from existing pre-Plan-1 assets:

| New file | Source(s) |
|---|---|
| `scripts/components/thehive-cortex/deploy.sh` | `stacks/thehive-cortex/{docker-compose.yml,setup.sh}` + `scripts/setup/components/{thehive,cortex}.sh` |
| `scripts/components/misp/deploy.sh` | `stacks/misp/{docker-compose.yml,setup.sh}` + `scripts/setup/components/misp.sh` |
| `scripts/components/zeek-suricata/deploy.sh` | `scripts/setup/components/{zeek,suricata}.sh` |
| `scripts/components/dashboards/deploy.sh` | `scripts/setup/components/dashboards.sh` |
| `scripts/components/mcp/deploy.sh` | NEW - clones 9 MCP server repos, installs Node, runs each as a systemd unit on SSE transport |

---

## Prerequisites

- On `feat/plan-2-components` branch (already created)
- Plan 1 merged (`v0.5.0` on `main`)
- proxmox-host SSH access for the smoke test (alias `proxmox-host`)
- `apt` available on proxmox-host (Proxmox host)
- `jq` will be installed by `bootstrap_deps` if missing
- Test VMID range `9000-9099` reserved on proxmox-host

---

# Phase A: Orchestrator plumbing fixes

## Task 1: Preset-gate the `wazuh-install.sh -i` flag

**Files:**
- Modify: `scripts/components/wazuh/deploy.sh`

The current implementation passes `-i` unconditionally, suppressing the hardware check even on `standard` and `production` presets where the LXC actually meets Wazuh's 4GB/2c minimum. Only `minimal` preset (2GB/1c) needs `-i`.

- [ ] **Step 1: Read the current deploy.sh**

```bash
cd ~/repos/soc-stack
grep -n 'wazuh-install.sh' scripts/components/wazuh/deploy.sh
```
Expect 5 lines (one per --generate-config-files, --wazuh-indexer, --start-cluster, --wazuh-server, --wazuh-dashboard).

- [ ] **Step 2: Add a preset-gated WAZUH_INSTALL_FLAGS variable**

At the top of the fresh-install section (right after the `log "Updating apt"` line and before `apt-get update`), add:

```bash
# Wazuh-install hardware check: required on minimal preset (2GB/1c), not needed
# on standard (4GB/2c) or production (8GB/4c) which already meet the upstream
# 4GB/2c floor.
WAZUH_INSTALL_FLAGS=""
if [[ "${SOC_PRESET:-standard}" == "minimal" ]]; then
  WAZUH_INSTALL_FLAGS="-i"
  log "preset=minimal: passing -i to wazuh-install.sh to skip hardware check"
fi
```

Then change each of the 5 `bash wazuh-install.sh ...` lines to use the flag:

```bash
bash wazuh-install.sh ${WAZUH_INSTALL_FLAGS} --generate-config-files
bash wazuh-install.sh ${WAZUH_INSTALL_FLAGS} --wazuh-indexer node-1
bash wazuh-install.sh ${WAZUH_INSTALL_FLAGS} --start-cluster
bash wazuh-install.sh ${WAZUH_INSTALL_FLAGS} --wazuh-server wazuh-1
bash wazuh-install.sh ${WAZUH_INSTALL_FLAGS} --wazuh-dashboard dashboard
```

Also remove the old `log "Using -i ..."` line that was added unconditionally, since the new code logs only when the flag is active.

- [ ] **Step 3: Shellcheck (expect SC2086 on the unquoted `${WAZUH_INSTALL_FLAGS}` since we want word-splitting when it's empty)**

```bash
shellcheck scripts/components/wazuh/deploy.sh
```

If SC2086 fires on the new lines, add inline directives:
```bash
# shellcheck disable=SC2086  # intentional - empty WAZUH_INSTALL_FLAGS expands to nothing
bash wazuh-install.sh ${WAZUH_INSTALL_FLAGS} --generate-config-files
```
Apply to each of the 5 lines.

- [ ] **Step 4: Unit suite regression check**

```bash
./tests/unit/run.sh
```
Expect 71/71 still passing.

- [ ] **Step 5: Commit**

```bash
git add scripts/components/wazuh/deploy.sh
git commit -m "fix(wazuh): preset-gate -i flag (only minimal needs hardware-check bypass)"
```

---

## Task 2: Add `emit_mcp_config()` to `lib/json-out.sh` with TDD

**Files:**
- Create: `tests/unit/test_mcp_config_emit.bats`
- Modify: `scripts/lib/json-out.sh`

The `--mcp-config-out` flag is advertised but never writes a file (caught in Plan 1 final review). Implement it. The MCP component's state file will include a `mcp_endpoints` array; `emit_mcp_config` reads that and writes a paste-ready MCP client config.

- [ ] **Step 1: Write failing tests**

Create `tests/unit/test_mcp_config_emit.bats`:

```bash
#!/usr/bin/env bats

load helpers/load.bash

setup() {
  export SOC_STATE_DIR="${BATS_TEST_TMPDIR}/var/lib/soc-stack"
  export SOC_LOG_FILE="${BATS_TEST_TMPDIR}/soc-stack.log"
  mkdir -p "${SOC_STATE_DIR}/state"
  source_lib logging
  source "${REPO_ROOT}/scripts/lib/json-out.sh"
}

@test "emit_mcp_config writes empty mcpServers when no mcp state present" {
  local out="${BATS_TEST_TMPDIR}/mcp.json"
  emit_mcp_config "${out}"
  jq -e '.mcpServers' "${out}" >/dev/null
  jq -e '.mcpServers | length == 0' "${out}"
}

@test "emit_mcp_config reads mcp state and produces paste-ready config" {
  cat > "${SOC_STATE_DIR}/state/mcp.json" <<'EOF'
{
  "component": "mcp",
  "status": "deployed",
  "mcp_endpoints": [
    {"name": "wazuh", "url": "http://10.0.50.99:3001/sse", "token": "abc123"},
    {"name": "thehive", "url": "http://10.0.50.99:3002/sse", "token": "def456"}
  ]
}
EOF
  local out="${BATS_TEST_TMPDIR}/mcp.json"
  emit_mcp_config "${out}"
  jq -e '.mcpServers.wazuh.type == "sse"' "${out}"
  jq -e '.mcpServers.wazuh.url == "http://10.0.50.99:3001/sse"' "${out}"
  jq -e '.mcpServers.wazuh.headers.Authorization == "Bearer abc123"' "${out}"
  jq -e '.mcpServers.thehive.url == "http://10.0.50.99:3002/sse"' "${out}"
  jq -e '.raw_endpoints | length == 2' "${out}"
  jq -e '.comment' "${out}" >/dev/null
}

@test "emit_mcp_config preserves all 9 servers if present" {
  local servers='[]'
  for n in wazuh thehive cortex misp zeek suricata mitre rapid7 sophos; do
    servers="$(jq --arg n "$n" --arg url "http://10.0.50.99:3001/sse" --arg tok "tok-$n" \
      '. + [{name:$n,url:$url,token:$tok}]' <<< "${servers}")"
  done
  jq -n --argjson eps "${servers}" '{
    component: "mcp",
    status: "deployed",
    mcp_endpoints: $eps
  }' > "${SOC_STATE_DIR}/state/mcp.json"

  local out="${BATS_TEST_TMPDIR}/mcp.json"
  emit_mcp_config "${out}"
  jq -e '.mcpServers | length == 9' "${out}"
  jq -e '.mcpServers.sophos | has("url") and has("type") and has("headers")' "${out}"
}
```

- [ ] **Step 2: Run, verify 3 FAIL**

```bash
./tests/vendor/bats-core/bin/bats --print-output-on-failure tests/unit/test_mcp_config_emit.bats
```

- [ ] **Step 3: Implement `emit_mcp_config()` in `scripts/lib/json-out.sh`**

Append to the end of `scripts/lib/json-out.sh`:

```bash
# emit_mcp_config <output_path>
# Reads the mcp component's state file (if any) and writes a paste-ready
# MCP client config to <output_path>. The output has:
#   .comment        - human-readable hint
#   .mcpServers     - keyed by server name; each {type, url, headers.Authorization}
#   .raw_endpoints  - array of {name, url, token} for non-Claude clients
# When the mcp state is absent or empty, .mcpServers is {} and .raw_endpoints is [].
emit_mcp_config() {
  local out="$1"
  local mcp_state="${SOC_STATE_DIR}/state/mcp.json"

  local endpoints='[]'
  if [[ -f "${mcp_state}" ]]; then
    endpoints="$(jq '.mcp_endpoints // []' "${mcp_state}")"
  fi

  jq -n --argjson eps "${endpoints}" '
    {
      comment: "Paste the mcpServers block into your MCP client config (Claude Desktop, OpenClaw, etc).",
      mcpServers: ($eps | map({(.name): {
        type: "sse",
        url: .url,
        headers: { Authorization: ("Bearer " + .token) }
      }}) | add // {}),
      raw_endpoints: $eps
    }' > "${out}"
}
```

- [ ] **Step 4: Re-run, verify 3 PASS**

```bash
./tests/vendor/bats-core/bin/bats --print-output-on-failure tests/unit/test_mcp_config_emit.bats
```

- [ ] **Step 5: Shellcheck**

```bash
shellcheck scripts/lib/json-out.sh
```
Clean.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/json-out.sh tests/unit/test_mcp_config_emit.bats
git commit -m "lib(json-out): add emit_mcp_config for paste-ready MCP client config"
```

---

## Task 3: Wire `--mcp-config-out` to call `emit_mcp_config` in `scripts/install.sh`

**Files:**
- Modify: `scripts/install.sh`

- [ ] **Step 1: Find the existing `emit_final_json` call in `main()`**

```bash
grep -n 'emit_final_json' scripts/install.sh
```

- [ ] **Step 2: Add `emit_mcp_config` call right after it**

After the `emit_final_json "${OPT_JSON_OUT}"` line in `main()`, add:

```bash
  emit_mcp_config "${OPT_MCP_CONFIG_OUT}"
  msg_ok "MCP client config written to ${OPT_MCP_CONFIG_OUT}"
```

- [ ] **Step 3: Smoke test - dry-run prints both files**

```bash
sudo bash scripts/install.sh --components wazuh --preset minimal \
  --state-dir /tmp/install-test-state --json-out /tmp/install-test.json \
  --mcp-config-out /tmp/install-test-mcp.json --dry-run 2>&1 | tail -10
```

(This may fail at check_root or check_proxmox; that's OK for this smoke - we're just confirming the script doesn't have a syntax error.)

- [ ] **Step 4: Shellcheck**

```bash
shellcheck scripts/install.sh
```

- [ ] **Step 5: Unit suite still green**

```bash
./tests/unit/run.sh
```
Expect 74/74 (71 prior + 3 from Task 2).

- [ ] **Step 6: Commit**

```bash
git add scripts/install.sh
git commit -m "orchestrator: wire --mcp-config-out to emit_mcp_config"
```

---

## Task 4: Add `--manifest <path>` mode to orchestrator with TDD

**Files:**
- Create: `tests/unit/test_orchestrator_manifest_mode.bats`
- Modify: `scripts/install.sh`

When `--manifest <path>` is passed, the orchestrator reads the JSON manifest INSTEAD of the OPT_* flag globals. Flag-based fallback continues to work when `--manifest` is absent.

- [ ] **Step 1: Write failing tests**

Create `tests/unit/test_orchestrator_manifest_mode.bats`:

```bash
#!/usr/bin/env bats

load helpers/load.bash

setup() {
  export SOC_LOG_FILE="${BATS_TEST_TMPDIR}/soc-stack.log"
  export SOC_TEST_MODE=1
  source "${REPO_ROOT}/scripts/install.sh"
}

@test "build_manifest uses the manifest file when --manifest given" {
  local mfile="${BATS_TEST_TMPDIR}/m.json"
  cat > "${mfile}" <<'EOF'
{
  "components": ["wazuh", "misp"],
  "preset": "production",
  "network": { "bridge": "vmbr5", "storage": "fast-lvm", "ip_mode": "dhcp" },
  "vmid_start": 7000
}
EOF
  parse_args --manifest "${mfile}"
  local out
  out="$(build_manifest)"
  jq -e '.components | length == 2' <<< "${out}"
  jq -e '.components | contains(["wazuh","misp"])' <<< "${out}"
  jq -e '.preset == "production"' <<< "${out}"
  jq -e '.network.bridge == "vmbr5"' <<< "${out}"
  jq -e '.vmid_start == 7000' <<< "${out}"
}

@test "manifest mode + CLI flag override: flag wins for that key" {
  local mfile="${BATS_TEST_TMPDIR}/m.json"
  cat > "${mfile}" <<'EOF'
{
  "components": ["wazuh"],
  "preset": "minimal",
  "network": { "bridge": "vmbr0", "storage": "local-lvm", "ip_mode": "dhcp" }
}
EOF
  parse_args --manifest "${mfile}" --preset production
  local out
  out="$(build_manifest)"
  jq -e '.preset == "production"' <<< "${out}"   # CLI override wins
  jq -e '.components | contains(["wazuh"])' <<< "${out}"   # manifest preserved
}

@test "manifest mode rejects malformed JSON" {
  local mfile="${BATS_TEST_TMPDIR}/bad.json"
  echo '{ broken' > "${mfile}"
  parse_args --manifest "${mfile}"
  run build_manifest
  [[ "$status" -ne 0 ]]
}

@test "manifest mode rejects manifest with unknown component" {
  local mfile="${BATS_TEST_TMPDIR}/m.json"
  cat > "${mfile}" <<'EOF'
{
  "components": ["wazuh", "imaginary"],
  "preset": "standard",
  "network": { "bridge": "vmbr0", "ip_mode": "dhcp" }
}
EOF
  parse_args --manifest "${mfile}"
  run build_manifest
  [[ "$status" -ne 0 ]]
  [[ "${output}${stderr:-}" == *"imaginary"* || "${output}${stderr:-}" == *"unknown"* ]]
}
```

- [ ] **Step 2: Run, verify 4 FAIL**

```bash
./tests/vendor/bats-core/bin/bats --print-output-on-failure tests/unit/test_orchestrator_manifest_mode.bats
```

- [ ] **Step 3: Modify `build_manifest()` in `scripts/install.sh`**

Find the current `build_manifest()` function. Replace it with:

```bash
# build_manifest
# Returns a manifest JSON document on stdout.
#
# If OPT_MANIFEST is set, reads that file as the base and merges any non-default
# CLI overrides on top (only flags the user explicitly set override the manifest;
# default values do not).
#
# If OPT_MANIFEST is unset, constructs the manifest from OPT_* globals as before.
#
# Returns non-zero (with stderr message) on malformed manifest or unknown component.
build_manifest() {
  local manifest

  if [[ -n "${OPT_MANIFEST}" ]]; then
    if [[ ! -f "${OPT_MANIFEST}" ]]; then
      printf 'manifest file not found: %s\n' "${OPT_MANIFEST}" >&2
      return 1
    fi
    if ! manifest="$(jq -c . "${OPT_MANIFEST}" 2>/dev/null)"; then
      printf 'manifest is not valid JSON: %s\n' "${OPT_MANIFEST}" >&2
      return 1
    fi

    # Apply user-set CLI overrides. We detect "user set" by comparing OPT_* to
    # the documented defaults. Only non-default OPT_* values override.
    if [[ "${OPT_COMPONENTS}" != "all" ]]; then
      manifest="$(jq --arg v "${OPT_COMPONENTS}" '.components = ($v | split(","))' <<< "${manifest}")"
    fi
    if [[ "${OPT_PRESET}" != "standard" ]]; then
      manifest="$(jq --arg v "${OPT_PRESET}" '.preset = $v' <<< "${manifest}")"
    fi
    if [[ "${OPT_BRIDGE}" != "vmbr0" ]]; then
      manifest="$(jq --arg v "${OPT_BRIDGE}" '.network.bridge = $v' <<< "${manifest}")"
    fi
    if [[ -n "${OPT_STORAGE}" ]]; then
      manifest="$(jq --arg v "${OPT_STORAGE}" '.network.storage = $v' <<< "${manifest}")"
    fi
    if [[ "${OPT_IP_MODE}" != "dhcp" ]]; then
      manifest="$(jq --arg v "${OPT_IP_MODE}" '.network.ip_mode = $v' <<< "${manifest}")"
    fi
    if [[ -n "${OPT_IP_RANGE}" ]]; then
      manifest="$(jq --arg v "${OPT_IP_RANGE}" '.network.ip_range = $v' <<< "${manifest}")"
    fi
    if [[ -n "${OPT_VLAN}" ]]; then
      manifest="$(jq --arg v "${OPT_VLAN}" '.network.vlan = $v' <<< "${manifest}")"
    fi
    if [[ "${OPT_VMID_START}" != "0" ]]; then
      manifest="$(jq --argjson v "${OPT_VMID_START}" '.vmid_start = $v' <<< "${manifest}")"
    fi
  else
    # Flag-only mode (Plan 1 behavior)
    local components_list
    components_list="$(expand_components "${OPT_COMPONENTS}")"
    local components_json
    # shellcheck disable=SC2086
    components_json="$(printf '%s\n' ${components_list} | jq -R . | jq -s .)"

    manifest="$(jq -n \
      --argjson components "${components_json}" \
      --arg preset "${OPT_PRESET}" \
      --arg bridge "${OPT_BRIDGE}" \
      --arg storage "${OPT_STORAGE}" \
      --arg ip_mode "${OPT_IP_MODE}" \
      --arg ip_range "${OPT_IP_RANGE}" \
      --arg vlan "${OPT_VLAN}" \
      --argjson vmid_start "${OPT_VMID_START}" \
      '{
        components: $components,
        preset: $preset,
        network: {
          bridge: $bridge,
          storage: (if $storage == "" then null else $storage end),
          ip_mode: $ip_mode,
          ip_range: (if $ip_range == "" then null else $ip_range end),
          vlan: (if $vlan == "" then null else $vlan end)
        },
        vmid_start: $vmid_start
      }')"
  fi

  # Validate every component is known
  local c
  while IFS= read -r c; do
    [[ -n "${c}" ]] || continue
    local known=0
    local k
    for k in "${COMPONENTS_KNOWN[@]}"; do
      [[ "${k}" == "${c}" ]] && { known=1; break; }
    done
    if [[ "${known}" -ne 1 ]]; then
      printf 'unknown component: %s\n' "${c}" >&2
      return 1
    fi
  done < <(jq -r '.components[]' <<< "${manifest}")

  printf '%s\n' "${manifest}"
}
```

- [ ] **Step 4: Run, verify 4 PASS + no regression in prior manifest-building tests**

```bash
./tests/vendor/bats-core/bin/bats --print-output-on-failure \
  tests/unit/test_orchestrator_manifest_mode.bats \
  tests/unit/test_orchestrator_manifest_building.bats
```

- [ ] **Step 5: Full suite**

```bash
./tests/unit/run.sh
```
Expect 78/78 (74 prior + 4 new).

- [ ] **Step 6: Shellcheck**

```bash
shellcheck scripts/install.sh
```

- [ ] **Step 7: Commit**

```bash
git add scripts/install.sh tests/unit/test_orchestrator_manifest_mode.bats
git commit -m "orchestrator: support --manifest <path> mode (TDD)"
```

---

# Phase B: TheHive + Cortex component

This single LXC runs both TheHive 5 and Cortex 3 via the existing Docker Compose stack in `stacks/thehive-cortex/`. The component reuses the existing compose file content (Cassandra + Elasticsearch + TheHive + Cortex) and `setup.sh` automation (admin password change + API key generation), but adapts them to the new contract (writes state JSON, idempotent, pulls back via `pct pull`).

## Task 5: Create `scripts/components/thehive-cortex/manifest.jsonc`

**Files:**
- Create: `scripts/components/thehive-cortex/manifest.jsonc`

- [ ] **Step 1: Write manifest**

```jsonc
{
  "name": "thehive-cortex",
  "display_name": "TheHive + Cortex",
  "description": "Case management (TheHive 5) and SOAR with analyzer engine (Cortex 3), backed by Elasticsearch 7 and Cassandra 4",
  "depends_on": [],
  "provides": ["thehive_url", "thehive_api_key", "cortex_url", "cortex_api_key"],
  "presets": {
    "minimal":    { "ram_mb": 4096, "disk_gb": 30, "cores": 2 },
    "standard":   { "ram_mb": 6144, "disk_gb": 50, "cores": 2 },
    "production": { "ram_mb": 12288, "disk_gb": 80, "cores": 4 }
  },
  "ports": [9000, 9001],
  "template_pattern": "ubuntu-22.04-standard",
  "features": ["nesting=1", "keyctl=1"],
  "unprivileged": true,
  "install_method": "docker-compose",
  "default_creds": {
    "thehive_user": "admin@thehive.local",
    "cortex_user": "thehive",
    "rotate_on_install": true
  }
}
```

NOTE: minimal preset is 4GB/2c here (not 2GB/1c like Wazuh). Java services need more memory; below this Elasticsearch OOMs and the compose stack will not boot.

- [ ] **Step 2: Validate JSON**

```bash
sed 's://.*$::g' scripts/components/thehive-cortex/manifest.jsonc | jq -e .
```

- [ ] **Step 3: Commit**

```bash
git add scripts/components/thehive-cortex/manifest.jsonc
git commit -m "components: add thehive-cortex manifest.jsonc"
```

---

## Task 6: Create `scripts/components/thehive-cortex/lxc-spec.sh`

**Files:**
- Create: `scripts/components/thehive-cortex/lxc-spec.sh`

- [ ] **Step 1: Write spec emitter**

```bash
#!/usr/bin/env bash
# scripts/components/thehive-cortex/lxc-spec.sh
# Emits LXC creation flags for TheHive + Cortex (Docker Compose inside one LXC).
# Inputs (env):
#   SOC_PRESET           - minimal|standard|production
#   SOC_NETWORK_CONFIG   - pre-built --net0 string
#   SOC_STORAGE          - storage pool

set -euo pipefail

case "${SOC_PRESET:-standard}" in
  minimal)    RAM=4096; DISK=30; CORES=2 ;;
  standard)   RAM=6144; DISK=50; CORES=2 ;;
  production) RAM=12288; DISK=80; CORES=4 ;;
  *) echo "unknown preset: ${SOC_PRESET}" >&2; exit 1 ;;
esac

cat <<EOF
--memory ${RAM}
--cores ${CORES}
--rootfs ${SOC_STORAGE:-local-lvm}:${DISK}
--net0 ${SOC_NETWORK_CONFIG:-name=eth0,bridge=vmbr0,ip=dhcp}
--unprivileged 1
--features nesting=1,keyctl=1
--onboot 1
--start 0
EOF
```

- [ ] **Step 2: chmod, smoke test**

```bash
chmod +x scripts/components/thehive-cortex/lxc-spec.sh
SOC_PRESET=minimal SOC_STORAGE=local-lvm ./scripts/components/thehive-cortex/lxc-spec.sh
```
Expect `--memory 4096` on first line.

- [ ] **Step 3: Shellcheck**

```bash
shellcheck scripts/components/thehive-cortex/lxc-spec.sh
```

- [ ] **Step 4: Commit**

```bash
git add scripts/components/thehive-cortex/lxc-spec.sh
git commit -m "components(thehive-cortex): add lxc-spec.sh (needs keyctl for Cassandra+ES)"
```

---

## Task 7: Create `scripts/components/thehive-cortex/deploy.sh`

**Files:**
- Create: `scripts/components/thehive-cortex/deploy.sh`

This script migrates the bulk of `stacks/thehive-cortex/setup.sh` (admin password rotation, Cortex first-run wizard automation, API key extraction) into the new component contract. The docker-compose.yml content is embedded as a heredoc.

- [ ] **Step 1: Read the existing setup.sh to understand the password/CSRF dance**

```bash
cat stacks/thehive-cortex/setup.sh | head -80
```

Key behaviors to preserve:
- Wait for Cassandra + Elasticsearch + TheHive + Cortex to all become healthy
- Run Cortex first-run wizard via API (creates default org + initial superadmin)
- Generate API keys for TheHive and Cortex
- Cortex POST endpoints require a CSRF token from a prior GET (handled in original setup.sh)
- TheHive password change uses `POST /password/change` (NOT `PATCH /user`)

- [ ] **Step 2: Read the existing docker-compose.yml**

```bash
cat stacks/thehive-cortex/docker-compose.yml
```

Note: ports 9000 (TheHive), 9001 (Cortex). Backed by Elasticsearch 7.17 + Cassandra 4.1.

- [ ] **Step 3: Write `scripts/components/thehive-cortex/deploy.sh`**

```bash
#!/usr/bin/env bash
# scripts/components/thehive-cortex/deploy.sh
# Runs INSIDE the thehive-cortex LXC. Idempotent. Deploys the Docker Compose
# stack and configures admin accounts + API keys.
#
# Required env (set by orchestrator):
#   SOC_STATE_DIR        - local-to-LXC dir; orchestrator pulls it back via pct pull
#   SOC_COMPONENT        - "thehive-cortex"
#   SOC_PRESET           - informational
#   SOC_NON_INTERACTIVE  - "1"
#
# Result JSON keys (written to ${SOC_STATE_DIR}/state/thehive-cortex.json on success):
#   status, thehive.{url,api_url,admin_user,admin_password,api_key},
#   cortex.{url,admin_user,admin_password,api_key,org}

set -euo pipefail

: "${SOC_STATE_DIR:?SOC_STATE_DIR must be set}"
: "${SOC_COMPONENT:=thehive-cortex}"

STATE_FILE="${SOC_STATE_DIR}/state/${SOC_COMPONENT}.json"
SECRETS_DIR="${SOC_STATE_DIR}/secrets"
STACK_DIR="/opt/soc-stack/thehive-cortex"
mkdir -p "${SOC_STATE_DIR}/state" "${SECRETS_DIR}" "${STACK_DIR}"

log()  { printf '[thc-deploy] %s\n' "$*"; }

write_failed() {
  local err="$1"
  jq -n --arg err "${err}" '{
    component: "thehive-cortex",
    status: "failed",
    error: $err
  }' > "${STATE_FILE}"
  log "FAILED: ${err}"
  exit 1
}
trap 'write_failed "deploy.sh aborted on line $LINENO"' ERR

# --- Idempotency: already running and healthy? ---
if docker compose -f "${STACK_DIR}/docker-compose.yml" ps 2>/dev/null | grep -q "thehive.*running" \
   && docker compose -f "${STACK_DIR}/docker-compose.yml" ps 2>/dev/null | grep -q "cortex.*running"; then
  log "stack already running, refreshing state"
  IP="$(hostname -I | awk '{print $1}')"

  THEHIVE_PASS="$(cat "${SECRETS_DIR}/thehive-admin.txt" 2>/dev/null || echo "")"
  THEHIVE_KEY="$(cat "${SECRETS_DIR}/thehive-apikey.txt" 2>/dev/null || echo "")"
  CORTEX_PASS="$(cat "${SECRETS_DIR}/cortex-admin.txt" 2>/dev/null || echo "")"
  CORTEX_KEY="$(cat "${SECRETS_DIR}/cortex-apikey.txt" 2>/dev/null || echo "")"

  jq -n \
    --arg ip "${IP}" \
    --arg thp "${THEHIVE_PASS}" --arg thk "${THEHIVE_KEY}" \
    --arg cxp "${CORTEX_PASS}"  --arg cxk "${CORTEX_KEY}" \
    '{
      component: "thehive-cortex",
      status: "deployed",
      thehive: {
        url: ("http://" + $ip + ":9000"),
        api_url: ("http://" + $ip + ":9000/api"),
        admin_user: "admin@thehive.local",
        admin_password: $thp,
        api_key: $thk
      },
      cortex: {
        url: ("http://" + $ip + ":9001"),
        admin_user: "admin",
        admin_password: $cxp,
        api_key: $cxk,
        org: "S3-CORTEX"
      },
      services: ["cassandra","elasticsearch","thehive","cortex"]
    }' > "${STATE_FILE}"
  exit 0
fi

# --- Fresh install ---
export DEBIAN_FRONTEND=noninteractive

log "installing docker engine + compose"
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg jq
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

log "writing docker-compose.yml"
cat > "${STACK_DIR}/docker-compose.yml" <<'COMPOSE_EOF'
services:
  cassandra:
    image: cassandra:4.1
    container_name: cassandra
    environment:
      - CASSANDRA_CLUSTER_NAME=thp
      - JVM_OPTS=-Xms512M -Xmx512M
    volumes:
      - cassandra-data:/var/lib/cassandra/data
    restart: unless-stopped

  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:7.17.20
    container_name: elasticsearch
    environment:
      - discovery.type=single-node
      - xpack.security.enabled=false
      - "ES_JAVA_OPTS=-Xms512m -Xmx512m"
      - thread_pool.search.queue_size=100000
      - thread_pool.write.queue_size=10000
    ulimits:
      memlock: { soft: -1, hard: -1 }
      nofile: { soft: 65536, hard: 65536 }
    volumes:
      - es-data:/usr/share/elasticsearch/data
    restart: unless-stopped

  thehive:
    image: strangebee/thehive:5.4
    container_name: thehive
    depends_on: [cassandra, elasticsearch]
    ports: ["9000:9000"]
    environment:
      - JVM_OPTS=-Xms1024M -Xmx1024M
    command:
      - --no-config
      - --no-config-secret
      - --secret=${THEHIVE_SECRET:-thp-secret-change-me}
      - --cql-hostnames=cassandra
      - --index-backend=elasticsearch
      - --es-hostnames=elasticsearch
      - --s3-endpoint=
    restart: unless-stopped

  cortex:
    image: thehiveproject/cortex:3.1.8
    container_name: cortex
    depends_on: [elasticsearch]
    ports: ["9001:9001"]
    environment:
      - JVM_OPTS=-Xms512M -Xmx512M
      - job_directory=/tmp/cortex-jobs
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    restart: unless-stopped

volumes:
  cassandra-data:
  es-data:
COMPOSE_EOF

log "starting compose stack (may take 3-5 minutes for Cassandra + ES warmup)"
docker compose -f "${STACK_DIR}/docker-compose.yml" up -d

wait_http() {
  local url="$1"
  local timeout="${2:-180}"
  local elapsed=0
  while (( elapsed < timeout )); do
    if curl -sf -o /dev/null --max-time 5 "${url}"; then return 0; fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  return 1
}

log "waiting for TheHive on :9000"
wait_http "http://localhost:9000/api/status" 300 || write_failed "TheHive did not become ready within 300s"
log "waiting for Cortex on :9001"
wait_http "http://localhost:9001/api/status" 300 || write_failed "Cortex did not become ready within 300s"

# --- Cortex first-run wizard ---
log "running Cortex first-run wizard"
# Cortex requires a session cookie + CSRF token dance
CJAR="$(mktemp)"
curl -sf -c "${CJAR}" "http://localhost:9001/" >/dev/null
CSRF="$(awk '/X-XSRF-TOKEN/ || /XSRF-TOKEN/ {print $7}' "${CJAR}" | head -1)"
# Migrate (initializes index)
curl -sf -b "${CJAR}" -c "${CJAR}" -H "X-XSRF-TOKEN: ${CSRF}" \
  -X POST "http://localhost:9001/api/maintenance/migrate" -d '{}' >/dev/null || true

CORTEX_ADMIN_PASS="$(LC_ALL=C tr -dc 'A-Za-z0-9_+=.-' </dev/urandom | head -c 24)"
curl -sf -b "${CJAR}" -c "${CJAR}" -H "X-XSRF-TOKEN: ${CSRF}" \
  -H "Content-Type: application/json" \
  -X POST "http://localhost:9001/api/user" \
  -d "{\"login\":\"admin\",\"name\":\"admin\",\"password\":\"${CORTEX_ADMIN_PASS}\",\"roles\":[\"superAdmin\"]}" >/dev/null

# Login as admin
curl -sf -c "${CJAR}" -H "Content-Type: application/json" \
  -X POST "http://localhost:9001/api/login" \
  -d "{\"user\":\"admin\",\"password\":\"${CORTEX_ADMIN_PASS}\"}" >/dev/null
CSRF="$(awk '/X-XSRF-TOKEN/ || /XSRF-TOKEN/ {print $7}' "${CJAR}" | head -1)"

# Create S3-CORTEX organization
curl -sf -b "${CJAR}" -c "${CJAR}" -H "X-XSRF-TOKEN: ${CSRF}" \
  -H "Content-Type: application/json" \
  -X POST "http://localhost:9001/api/organization" \
  -d '{"name":"S3-CORTEX","description":"S3 SOC Stack Cortex org","status":"Active"}' >/dev/null

# Create org-admin "thehive" user (for the TheHive-to-Cortex link) and key
curl -sf -b "${CJAR}" -c "${CJAR}" -H "X-XSRF-TOKEN: ${CSRF}" \
  -H "Content-Type: application/json" \
  -X POST "http://localhost:9001/api/user" \
  -d '{"login":"thehive","name":"thehive","organization":"S3-CORTEX","roles":["read","analyze"]}' >/dev/null

CORTEX_API_KEY="$(curl -sf -b "${CJAR}" -H "X-XSRF-TOKEN: ${CSRF}" \
  -X POST "http://localhost:9001/api/user/thehive/key/renew" | tr -d '"')"

# --- TheHive admin password rotation + API key ---
log "rotating TheHive admin password + minting API key"
THEHIVE_DEFAULT_PASS="secret"
THEHIVE_ADMIN_PASS="$(LC_ALL=C tr -dc 'A-Za-z0-9_+=.-' </dev/urandom | head -c 24)"

# Login with default
TCJAR="$(mktemp)"
curl -sf -c "${TCJAR}" -H "Content-Type: application/json" \
  -X POST "http://localhost:9000/api/v1/session" \
  -d "{\"login\":\"admin@thehive.local\",\"password\":\"${THEHIVE_DEFAULT_PASS}\"}" >/dev/null

# Change password (uses /password/change endpoint, NOT /user)
curl -sf -b "${TCJAR}" -H "Content-Type: application/json" \
  -X POST "http://localhost:9000/api/v1/user/admin%40thehive.local/password/change" \
  -d "{\"currentPassword\":\"${THEHIVE_DEFAULT_PASS}\",\"password\":\"${THEHIVE_ADMIN_PASS}\"}" >/dev/null

# Re-login with new password
TCJAR="$(mktemp)"
curl -sf -c "${TCJAR}" -H "Content-Type: application/json" \
  -X POST "http://localhost:9000/api/v1/session" \
  -d "{\"login\":\"admin@thehive.local\",\"password\":\"${THEHIVE_ADMIN_PASS}\"}" >/dev/null

# Mint API key
THEHIVE_API_KEY="$(curl -sf -b "${TCJAR}" -H "Content-Type: application/json" \
  -X POST "http://localhost:9000/api/v1/user/admin%40thehive.local/key/renew" | tr -d '"\n')"

# Persist secrets
printf '%s' "${THEHIVE_ADMIN_PASS}" > "${SECRETS_DIR}/thehive-admin.txt"
printf '%s' "${THEHIVE_API_KEY}"    > "${SECRETS_DIR}/thehive-apikey.txt"
printf '%s' "${CORTEX_ADMIN_PASS}"  > "${SECRETS_DIR}/cortex-admin.txt"
printf '%s' "${CORTEX_API_KEY}"     > "${SECRETS_DIR}/cortex-apikey.txt"
chmod 600 "${SECRETS_DIR}"/{thehive,cortex}-*.txt

IP="$(hostname -I | awk '{print $1}')"

jq -n \
  --arg ip "${IP}" \
  --arg thp "${THEHIVE_ADMIN_PASS}" --arg thk "${THEHIVE_API_KEY}" \
  --arg cxp "${CORTEX_ADMIN_PASS}"  --arg cxk "${CORTEX_API_KEY}" \
  '{
    component: "thehive-cortex",
    status: "deployed",
    thehive: {
      url: ("http://" + $ip + ":9000"),
      api_url: ("http://" + $ip + ":9000/api"),
      admin_user: "admin@thehive.local",
      admin_password: $thp,
      api_key: $thk
    },
    cortex: {
      url: ("http://" + $ip + ":9001"),
      admin_user: "admin",
      admin_password: $cxp,
      api_key: $cxk,
      org: "S3-CORTEX"
    },
    services: ["cassandra","elasticsearch","thehive","cortex"]
  }' > "${STATE_FILE}"

log "deploy complete: TheHive at http://${IP}:9000  Cortex at http://${IP}:9001"
trap - ERR
```

- [ ] **Step 4: chmod, shellcheck**

```bash
chmod +x scripts/components/thehive-cortex/deploy.sh
shellcheck scripts/components/thehive-cortex/deploy.sh
```

The deploy.sh runs INSIDE the LXC so it doesn't need to match host shellcheck rigor on every line. Acceptable to add `# shellcheck disable=` directives for any persistent warnings.

- [ ] **Step 5: Commit**

```bash
git add scripts/components/thehive-cortex/deploy.sh
git commit -m "components(thehive-cortex): add deploy.sh (docker compose, idempotent, writes state)"
```

---

## Task 8: Create `scripts/components/thehive-cortex/verify.sh`

**Files:**
- Create: `scripts/components/thehive-cortex/verify.sh`

- [ ] **Step 1: Write**

```bash
#!/usr/bin/env bash
# scripts/components/thehive-cortex/verify.sh
# Runs INSIDE the LXC. Exit 0 if healthy.

set -euo pipefail

fail=0
IP="$(hostname -I | awk '{print $1}')"

for svc_url in \
  "http://localhost:9000/api/status" \
  "http://localhost:9001/api/status" \
; do
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "${svc_url}")"
  if [[ "${code}" -lt 200 || "${code}" -ge 500 ]]; then
    printf '[verify] %s -> HTTP %s\n' "${svc_url}" "${code}" >&2
    fail=1
  fi
done

# Compose-level health
if ! docker compose -f /opt/soc-stack/thehive-cortex/docker-compose.yml ps 2>/dev/null \
     | grep -E '(thehive|cortex)' | grep -q running; then
  echo '[verify] one or more compose services not running' >&2
  fail=1
fi

exit "${fail}"
```

- [ ] **Step 2: chmod, shellcheck, commit**

```bash
chmod +x scripts/components/thehive-cortex/verify.sh
shellcheck scripts/components/thehive-cortex/verify.sh
git add scripts/components/thehive-cortex/verify.sh
git commit -m "components(thehive-cortex): add verify.sh health check"
```

---

## Task 9: Create `scripts/components/thehive-cortex/integrate.sh`

**Files:**
- Create: `scripts/components/thehive-cortex/integrate.sh`

This integrate.sh runs on the Proxmox host AFTER all components deploy. It does TWO things:
1. Wires TheHive to use the Cortex instance (TheHive reads Cortex peer state, posts config to its own admin API).
2. No outbound integrations to non-self peers - TheHive is consumed BY others (Wazuh writes alerts to TheHive); that direction is in `wazuh/integrate.sh`.

- [ ] **Step 1: Write**

```bash
#!/usr/bin/env bash
# scripts/components/thehive-cortex/integrate.sh
# Runs on the Proxmox HOST after deploy. Wires TheHive <-> Cortex API connection.

set -euo pipefail

: "${SOC_STATE_DIR:?SOC_STATE_DIR must be set}"

log() { printf '[thc-integrate] %s\n' "$*"; }

STATE="${SOC_STATE_DIR}/state/thehive-cortex.json"
[[ -f "${STATE}" ]] || { log "thehive-cortex state missing, skipping"; exit 0; }

thehive_url="$(jq -r '.thehive.url // empty' "${STATE}")"
thehive_key="$(jq -r '.thehive.api_key // empty' "${STATE}")"
cortex_url="$(jq -r '.cortex.url // empty' "${STATE}")"
cortex_key="$(jq -r '.cortex.api_key // empty' "${STATE}")"

if [[ -z "${thehive_url}" || -z "${cortex_url}" || -z "${cortex_key}" ]]; then
  log "missing thehive/cortex coords, cannot wire"
  exit 0
fi

# TheHive -> Cortex connector config (admin API)
# TheHive 5 API: POST /api/config/cortex with the Cortex server entry.
# Idempotent: if a server named "S3-CORTEX" is already configured, skip.
existing="$(curl -sf -H "Authorization: Bearer ${thehive_key}" \
  "${thehive_url}/api/v1/config/cortex" 2>/dev/null \
  | jq -r '.servers[]?.name' 2>/dev/null | grep -x "S3-CORTEX" || true)"

if [[ -n "${existing}" ]]; then
  log "Cortex link already configured in TheHive, skipping"
  exit 0
fi

cortex_internal_url="${cortex_url}"  # same LXC, but TheHive will hit it via internal docker network when run inline. Use the external URL since compose exposes it.

payload="$(jq -n \
  --arg name "S3-CORTEX" \
  --arg url "${cortex_internal_url}" \
  --arg key "${cortex_key}" \
  '{servers: [{name: $name, url: $url, auth: {type: "bearer", key: $key}}]}')"

if curl -sf -H "Authorization: Bearer ${thehive_key}" \
  -H "Content-Type: application/json" \
  -X PUT "${thehive_url}/api/v1/config/cortex" \
  -d "${payload}" >/dev/null; then
  log "TheHive -> Cortex link configured"
else
  log "WARN: TheHive -> Cortex link config failed (manual fixup may be required)"
fi

exit 0
```

- [ ] **Step 2: chmod, shellcheck, commit**

```bash
chmod +x scripts/components/thehive-cortex/integrate.sh
shellcheck scripts/components/thehive-cortex/integrate.sh
git add scripts/components/thehive-cortex/integrate.sh
git commit -m "components(thehive-cortex): add integrate.sh wiring TheHive -> Cortex"
```

---

## Task 10: Create `scripts/components/thehive-cortex/destroy.sh`

**Files:**
- Create: `scripts/components/thehive-cortex/destroy.sh`

- [ ] **Step 1: Write**

```bash
#!/usr/bin/env bash
# scripts/components/thehive-cortex/destroy.sh
# Runs on Proxmox HOST. Tears down the LXC + removes state file.

set -euo pipefail

: "${SOC_STATE_DIR:?SOC_STATE_DIR must be set}"
STATE_FILE="${SOC_STATE_DIR}/state/thehive-cortex.json"
log() { printf '[thc-destroy] %s\n' "$*"; }

if [[ ! -f "${STATE_FILE}" ]]; then
  log "no state file, nothing to destroy"; exit 0
fi

VMID="$(jq -r '.lxc.vmid // empty' "${STATE_FILE}")"
if [[ -z "${VMID}" ]]; then
  log "no VMID, removing state only"; rm -f "${STATE_FILE}"; exit 0
fi

pct stop "${VMID}" 2>/dev/null || true
pct destroy "${VMID}" 2>/dev/null || true
rm -f "${STATE_FILE}"
log "thehive-cortex teardown complete (VMID ${VMID})"
```

- [ ] **Step 2: chmod, shellcheck, commit**

```bash
chmod +x scripts/components/thehive-cortex/destroy.sh
shellcheck scripts/components/thehive-cortex/destroy.sh
git add scripts/components/thehive-cortex/destroy.sh
git commit -m "components(thehive-cortex): add destroy.sh teardown"
```

---

## Task 11: Update wazuh/integrate.sh to actually wire the TheHive webhook

**Files:**
- Modify: `scripts/components/wazuh/integrate.sh`

In Plan 1 this was a stub. Now that TheHive deploys, write the actual integration: a `custom-thehive.py` Wazuh integration script + ossec.conf entry.

- [ ] **Step 1: Replace the stub body**

Open `scripts/components/wazuh/integrate.sh` and replace the contents with:

```bash
#!/usr/bin/env bash
# scripts/components/wazuh/integrate.sh
# Runs on the Proxmox HOST after all components are deployed.
# Wires Wazuh alerts to a TheHive webhook.

set -euo pipefail

: "${SOC_STATE_DIR:?SOC_STATE_DIR must be set}"

log() { printf '[wazuh-integrate] %s\n' "$*"; }

WAZUH_STATE="${SOC_STATE_DIR}/state/wazuh.json"
THEHIVE_STATE="${SOC_STATE_DIR}/state/thehive-cortex.json"

if [[ ! -f "${WAZUH_STATE}" ]]; then
  log "wazuh state missing, skipping integration"
  exit 0
fi
wazuh_status="$(jq -r '.status // empty' "${WAZUH_STATE}")"
if [[ "${wazuh_status}" != "deployed" ]]; then
  log "wazuh status=${wazuh_status}, skipping"
  exit 0
fi
wazuh_vmid="$(jq -r '.lxc.vmid // empty' "${WAZUH_STATE}")"
[[ -n "${wazuh_vmid}" ]] || { log "wazuh has no VMID, skipping"; exit 0; }

if [[ ! -f "${THEHIVE_STATE}" ]]; then
  log "TheHive state missing, skipping Wazuh -> TheHive webhook"
  exit 0
fi
thehive_status="$(jq -r '.status // empty' "${THEHIVE_STATE}")"
if [[ "${thehive_status}" != "deployed" ]]; then
  log "TheHive status=${thehive_status}, skipping webhook wiring"
  exit 0
fi

thehive_url="$(jq -r '.thehive.url // empty' "${THEHIVE_STATE}")"
thehive_key="$(jq -r '.thehive.api_key // empty' "${THEHIVE_STATE}")"
[[ -n "${thehive_url}" && -n "${thehive_key}" ]] || {
  log "missing TheHive URL or API key, skipping"
  exit 0
}

log "configuring Wazuh -> TheHive webhook (vmid=${wazuh_vmid} -> ${thehive_url})"

# Push the integration script into the Wazuh LXC
INTEG_PY="/tmp/custom-thehive.py"
cat > "${INTEG_PY}" <<PYEOF
#!/usr/bin/env python3
"""custom-thehive: forward Wazuh alerts to TheHive 5."""
import json, sys, urllib.request, urllib.error

THEHIVE_URL = "${thehive_url}"
THEHIVE_API_KEY = "${thehive_key}"

def main():
    alert_file = sys.argv[1]
    with open(alert_file) as f:
        alert = json.load(f)
    severity_map = {1: 1, 2: 1, 3: 1, 4: 1, 5: 2, 6: 2, 7: 2, 8: 2, 9: 3, 10: 3, 11: 3, 12: 4, 13: 4, 14: 4, 15: 4}
    level = int(alert.get("rule", {}).get("level", 3))
    sev = severity_map.get(level, 2)
    payload = {
        "type": "wazuh",
        "source": "Wazuh SIEM",
        "sourceRef": str(alert.get("id", "unknown")),
        "title": alert.get("rule", {}).get("description", "Wazuh Alert"),
        "description": json.dumps(alert, indent=2),
        "severity": sev,
        "tlp": 2,
        "tags": ["wazuh", "s3-stack"]
    }
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        f"{THEHIVE_URL}/api/v1/alert",
        data=data,
        method="POST",
        headers={
            "Authorization": f"Bearer {THEHIVE_API_KEY}",
            "Content-Type": "application/json",
        },
    )
    try:
        urllib.request.urlopen(req, timeout=10)
    except urllib.error.HTTPError as e:
        # Treat 4xx/5xx as soft failures so Wazuh doesn't retry-storm
        print(f"thehive webhook returned {e.code}", file=sys.stderr)

if __name__ == "__main__":
    main()
PYEOF
pct push "${wazuh_vmid}" "${INTEG_PY}" /var/ossec/integrations/custom-thehive.py
pct exec "${wazuh_vmid}" -- chmod 750 /var/ossec/integrations/custom-thehive.py
pct exec "${wazuh_vmid}" -- chown root:wazuh /var/ossec/integrations/custom-thehive.py

# Insert <integration> block into ossec.conf (idempotent)
if ! pct exec "${wazuh_vmid}" -- grep -q "custom-thehive" /var/ossec/etc/ossec.conf; then
  pct exec "${wazuh_vmid}" -- bash -c "sed -i '/<\/ossec_config>/i\\
  <integration>\\
    <name>custom-thehive</name>\\
    <hook_url>${thehive_url}</hook_url>\\
    <level>8</level>\\
    <alert_format>json</alert_format>\\
  </integration>' /var/ossec/etc/ossec.conf"
  pct exec "${wazuh_vmid}" -- systemctl restart wazuh-manager
fi
rm -f "${INTEG_PY}"

# Mark integration in state
state_set_file="${SOC_STATE_DIR}/state/wazuh.json"
if command -v jq >/dev/null 2>&1; then
  tmp="$(mktemp)"
  jq '.integrations = ((.integrations // []) + [{to: "thehive-cortex", type: "webhook", status: "configured"}] | unique_by(.to + .type))' "${state_set_file}" > "${tmp}"
  mv "${tmp}" "${state_set_file}"
fi

log "Wazuh -> TheHive webhook configured"
exit 0
```

- [ ] **Step 2: shellcheck + commit**

```bash
shellcheck scripts/components/wazuh/integrate.sh
git add scripts/components/wazuh/integrate.sh
git commit -m "components(wazuh): wire real TheHive webhook in integrate.sh"
```

---

# Phase C: MISP component

## Task 12-17: MISP component module (manifest, lxc-spec, deploy, verify, integrate, destroy)

The MISP component follows the exact same pattern as TheHive+Cortex (Docker Compose + setup automation). To keep this plan tractable, I describe the deltas relative to TheHive+Cortex rather than rewriting all 5 files inline. The implementer reads `stacks/misp/{docker-compose.yml,setup.sh}` and adapts it to the new contract.

### Task 12: `scripts/components/misp/manifest.jsonc`

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
  "default_creds": {
    "user": "admin@admin.test",
    "rotate_on_install": true
  }
}
```

Commit: `components: add misp manifest.jsonc`

### Task 13: `scripts/components/misp/lxc-spec.sh`

Same template as `thehive-cortex/lxc-spec.sh` but with the misp presets (2GB/20/1, 4GB/40/2, 8GB/80/4). Features = `nesting=1`. Commit: `components(misp): add lxc-spec.sh`.

### Task 14: `scripts/components/misp/deploy.sh`

Pattern matches TheHive+Cortex but:
- Docker compose stack = misp-core (image: `coolacid/misp-docker:core-latest`), misp-modules, mariadb 10.11, redis 7
- Heredoc the compose file from `stacks/misp/docker-compose.yml` (read it first)
- Idempotency check: `docker compose ps | grep -q "misp-core.*running"`
- Wait-for-ready: `wait_http "https://localhost/users/heartbeat" 300` (note: HTTPS, self-signed)
- Admin password rotation via MISP's `/users/edit/1` endpoint (default user is `admin@admin.test` / `admin`)
- API key generation via `/users/getApiKey`
- Store + return `MISP_API_KEY` in state JSON
- CRITICAL: set `INNODB_BUFFER_POOL_SIZE=512M` in the mariadb service env to prevent OOM on 4GB hosts (per repo gotchas.md)

State JSON keys: `status, url, api_url, admin_user, admin_password, api_key, services`.

Commit: `components(misp): add deploy.sh (docker compose, idempotent)`.

### Task 15: `scripts/components/misp/verify.sh`

curl probe `https://localhost/users/heartbeat` (200 with `-k`), and `docker compose ps | grep misp-core.*running`.

Commit: `components(misp): add verify.sh`.

### Task 16: `scripts/components/misp/integrate.sh`

MISP doesn't have an outbound integration to non-self peers (MISP is CONSUMED by Suricata which pulls rules from it; that direction lives in `suricata`'s side or `zeek-suricata`'s integrate). Make this a no-op stub that logs "MISP is integrated INTO by other components (suricata rule feed)" and exits 0.

Commit: `components(misp): add integrate.sh (no outbound; consumed by suricata)`.

### Task 17: `scripts/components/misp/destroy.sh`

Identical pattern to thehive-cortex/destroy.sh, name swapped.

Commit: `components(misp): add destroy.sh teardown`.

---

# Phase D: Zeek + Suricata component (single LXC, both tools native-installed)

## Task 18-23: zeek-suricata component module

### Task 18: `scripts/components/zeek-suricata/manifest.jsonc`

```jsonc
{
  "name": "zeek-suricata",
  "display_name": "Zeek + Suricata",
  "description": "Network Security Monitoring (Zeek) + IDS/IPS (Suricata), single LXC, native install",
  "depends_on": [],
  "provides": ["zeek_log_dir", "suricata_eve_path"],
  "presets": {
    "minimal":    { "ram_mb": 2048, "disk_gb": 20, "cores": 1 },
    "standard":   { "ram_mb": 4096, "disk_gb": 40, "cores": 2 },
    "production": { "ram_mb": 8192, "disk_gb": 80, "cores": 4 }
  },
  "ports": [47760],
  "template_pattern": "ubuntu-22.04-standard",
  "features": ["nesting=1"],
  "unprivileged": true,
  "install_method": "native",
  "default_creds": null
}
```

Commit: `components: add zeek-suricata manifest.jsonc`.

### Task 19: `scripts/components/zeek-suricata/lxc-spec.sh`

Same template; presets per manifest above; features=`nesting=1`.

Commit: `components(zeek-suricata): add lxc-spec.sh`.

### Task 20: `scripts/components/zeek-suricata/deploy.sh`

Combines the existing `scripts/setup/components/zeek.sh` and `scripts/setup/components/suricata.sh` into one script that runs inside the LXC. Pattern:

```bash
#!/usr/bin/env bash
# scripts/components/zeek-suricata/deploy.sh
# Runs INSIDE the zeek-suricata LXC. Idempotent. Installs both tools native.

set -euo pipefail
: "${SOC_STATE_DIR:?}"; : "${SOC_COMPONENT:=zeek-suricata}"
STATE_FILE="${SOC_STATE_DIR}/state/${SOC_COMPONENT}.json"
SECRETS_DIR="${SOC_STATE_DIR}/secrets"
mkdir -p "${SOC_STATE_DIR}/state" "${SECRETS_DIR}"

log() { printf '[zs-deploy] %s\n' "$*"; }
write_failed() {
  jq -n --arg err "$1" '{component:"zeek-suricata",status:"failed",error:$err}' > "${STATE_FILE}"
  log "FAILED: $1"; exit 1
}
trap 'write_failed "aborted on line $LINENO"' ERR

# Idempotency: both services up?
if systemctl is-active --quiet zeek 2>/dev/null \
   && systemctl is-active --quiet suricata 2>/dev/null; then
  log "both services already running, refreshing state"
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl wget gnupg software-properties-common jq

# --- Install Zeek (official package repo) ---
if ! command -v zeek >/dev/null 2>&1; then
  log "installing Zeek from openSUSE Build Service repo"
  echo 'deb http://download.opensuse.org/repositories/security:/zeek/xUbuntu_22.04/ /' \
    > /etc/apt/sources.list.d/security:zeek.list
  curl -fsSL https://download.opensuse.org/repositories/security:zeek/xUbuntu_22.04/Release.key \
    | gpg --dearmor -o /etc/apt/trusted.gpg.d/security_zeek.gpg
  apt-get update -qq
  apt-get install -y -qq zeek-lts
fi
export PATH="/opt/zeek/bin:${PATH}"
echo 'export PATH="/opt/zeek/bin:$PATH"' > /etc/profile.d/zeek.sh

IFACE="$(ip route show default | awk '{print $5}' | head -1)"
IFACE="${IFACE:-eth0}"

# Configure Zeek node.cfg
if [[ -f /opt/zeek/etc/node.cfg ]]; then
  cat > /opt/zeek/etc/node.cfg <<EOF
[zeek]
type=standalone
host=localhost
interface=${IFACE}
EOF
fi
zeekctl deploy >/dev/null 2>&1 || true
systemctl enable --now zeek.service 2>/dev/null || true

# --- Install Suricata (PPA) ---
if ! command -v suricata >/dev/null 2>&1; then
  log "installing Suricata from oisf/suricata-stable PPA"
  add-apt-repository -y ppa:oisf/suricata-stable
  apt-get update -qq
  apt-get install -y -qq suricata suricata-update
fi
if [[ -f /etc/suricata/suricata.yaml ]]; then
  sed -i "s/- interface: eth0/- interface: ${IFACE}/" /etc/suricata/suricata.yaml
fi
suricata-update >/dev/null 2>&1 || true
systemctl enable --now suricata 2>/dev/null || true

IP="$(hostname -I | awk '{print $1}')"

jq -n \
  --arg ip "${IP}" \
  --arg iface "${IFACE}" \
  '{
    component: "zeek-suricata",
    status: "deployed",
    interface: $iface,
    zeek: {
      log_dir: "/opt/zeek/logs/current",
      config_dir: "/opt/zeek/etc"
    },
    suricata: {
      eve_path: "/var/log/suricata/eve.json",
      rules_dir: "/var/lib/suricata/rules",
      config: "/etc/suricata/suricata.yaml"
    },
    services: ["zeek","suricata"],
    host_ip: $ip
  }' > "${STATE_FILE}"

log "zeek + suricata deploy complete (iface=${IFACE})"
trap - ERR
```

chmod +x, shellcheck (add disables for any persistent warnings on the apt-key dance), commit: `components(zeek-suricata): add deploy.sh (native, both tools, idempotent)`.

### Task 21: `scripts/components/zeek-suricata/verify.sh`

`systemctl is-active --quiet zeek && systemctl is-active --quiet suricata` and existence-checks for `/opt/zeek/logs/current/conn.log` and `/var/log/suricata/eve.json` (created after first traffic; soft-warn if missing on a fresh install).

Commit: `components(zeek-suricata): add verify.sh`.

### Task 22: `scripts/components/zeek-suricata/integrate.sh`

Two integrations:
1. **Suricata -> MISP rule feed:** if `misp.json` exists with `status=deployed`, write `/etc/suricata/update.d/misp.conf` inside the zeek-suricata LXC pointing at `${misp_url}/attributes/restSearch/returnFormat:snort/type:snort` with the MISP API key, and a `/etc/cron.d/s3-misp-rules` for hourly rule sync.
2. **Zeek -> Wazuh agent forward:** if `wazuh.json` exists with `status=deployed`, install the Wazuh agent inside the zeek-suricata LXC pointing at `${wazuh_agent_endpoint}`, and add `<localfile>` blocks for conn.log/dns.log/http.log/ssl.log/notice.log to `/var/ossec/etc/ossec.conf`.

Both integrations are idempotent (grep for marker before applying).

Use `pct push` to deliver scripts/configs and `pct exec` to apply them.

Commit: `components(zeek-suricata): add integrate.sh (MISP rule feed + Wazuh agent forward)`.

### Task 23: `scripts/components/zeek-suricata/destroy.sh`

Standard teardown pattern matching thehive-cortex/destroy.sh.

Commit: `components(zeek-suricata): add destroy.sh teardown`.

---

# Phase E: Dashboards component (Bro Hunter + Playbook Forge)

## Task 24-29: dashboards component module

### Task 24: `scripts/components/dashboards/manifest.jsonc`

```jsonc
{
  "name": "dashboards",
  "display_name": "Bro Hunter + Playbook Forge",
  "description": "Custom dashboards: Zeek log hunter UI + IR playbook builder, served via nginx reverse proxy",
  "depends_on": [],
  "provides": ["bro_hunter_url", "playbook_forge_url"],
  "presets": {
    "minimal":    { "ram_mb": 1024, "disk_gb": 10, "cores": 1 },
    "standard":   { "ram_mb": 2048, "disk_gb": 15, "cores": 2 },
    "production": { "ram_mb": 4096, "disk_gb": 20, "cores": 2 }
  },
  "ports": [80, 5174, 5177],
  "template_pattern": "ubuntu-22.04-standard",
  "features": ["nesting=1"],
  "unprivileged": true,
  "install_method": "native",
  "default_creds": null
}
```

Commit: `components: add dashboards manifest.jsonc`.

### Task 25: `scripts/components/dashboards/lxc-spec.sh`

Same template.

Commit: `components(dashboards): add lxc-spec.sh`.

### Task 26: `scripts/components/dashboards/deploy.sh`

Migrate from `scripts/setup/components/dashboards.sh` (existing 243 lines) into the new contract. Same install steps:
- apt install nginx, Node.js 20, python3-venv, git
- git clone bro-hunter and playbook-forge from `https://github.com/solomonneas/bro_hunter.git` and `https://github.com/solomonneas/playbook-forge.git` into `/opt/s3-dashboards/{bro-hunter,playbook-forge}`
- `npm install` + `npm run build` in each
- systemd units `s3-bro-hunter` (port 5174) + `s3-playbook-forge` (port 5177)
- nginx config reverse-proxying `/bro-hunter/` -> 5174, `/playbook-forge/` -> 5177
- Idempotency: skip if both systemd units are active AND nginx is serving

Add state JSON output:
```json
{
  "component": "dashboards",
  "status": "deployed",
  "bro_hunter_url": "http://<ip>/bro-hunter/",
  "playbook_forge_url": "http://<ip>/playbook-forge/",
  "services": ["nginx", "s3-bro-hunter", "s3-playbook-forge"]
}
```

Commit: `components(dashboards): add deploy.sh (Bro Hunter + Playbook Forge in shared LXC)`.

### Task 27: `scripts/components/dashboards/verify.sh`

curl `http://localhost/bro-hunter/` and `http://localhost/playbook-forge/`, both must return 2xx/3xx. Both systemd services active.

Commit: `components(dashboards): add verify.sh`.

### Task 28: `scripts/components/dashboards/integrate.sh`

If zeek-suricata state exists and `status=deployed`, configure a bind-mount from the zeek-suricata LXC's `/opt/zeek/logs/` directory to this LXC's `/opt/s3-dashboards/zeek-logs/` via Proxmox host `pct set` (read-only mp). Existing pattern from `scripts/setup/install.sh:778-791`.

If zeek-suricata state is missing/failed, log "Zeek logs unavailable, Bro Hunter will run without live data" and exit 0.

Commit: `components(dashboards): add integrate.sh (zeek log bind-mount)`.

### Task 29: `scripts/components/dashboards/destroy.sh`

Standard teardown.

Commit: `components(dashboards): add destroy.sh`.

---

# Phase F: MCP servers component (NEW build)

This is the biggest new component. It deploys 9 MCP servers as systemd services running HTTP/SSE transport (not stdio) on a dedicated LXC. Each server gets a unique port (3001-3009), a bearer token, and is wired to its respective tool's API after integration.

## Task 30: `scripts/components/mcp/manifest.jsonc`

**Files:**
- Create: `scripts/components/mcp/manifest.jsonc`

```jsonc
{
  "name": "mcp",
  "display_name": "MCP Servers",
  "description": "9 MCP servers (wazuh, thehive, cortex, misp, zeek, suricata, mitre, rapid7, sophos) running HTTP/SSE transport in a dedicated LXC",
  "depends_on": ["wazuh", "thehive-cortex", "misp", "zeek-suricata"],
  "provides": ["mcp_endpoints"],
  "presets": {
    "minimal":    { "ram_mb": 1024, "disk_gb": 10, "cores": 1 },
    "standard":   { "ram_mb": 2048, "disk_gb": 15, "cores": 2 },
    "production": { "ram_mb": 4096, "disk_gb": 20, "cores": 2 }
  },
  "ports": [3001, 3002, 3003, 3004, 3005, 3006, 3007, 3008, 3009],
  "template_pattern": "ubuntu-22.04-standard",
  "features": ["nesting=1"],
  "unprivileged": true,
  "install_method": "native",
  "default_creds": null
}
```

The `depends_on` declares soft deps; mcp will deploy even if peers are missing, but its servers will be unconfigured (no API key) for missing peers and `integrate.sh` will re-configure them after peers come up.

Commit: `components: add mcp manifest.jsonc`.

---

## Task 31: `scripts/components/mcp/lxc-spec.sh`

**Files:**
- Create: `scripts/components/mcp/lxc-spec.sh`

Same template.

Commit: `components(mcp): add lxc-spec.sh`.

---

## Task 32: `scripts/components/mcp/deploy.sh`

**Files:**
- Create: `scripts/components/mcp/deploy.sh`

Big script. Clones 9 MCP server repos, installs Node 20, runs each as a systemd unit on its own port.

```bash
#!/usr/bin/env bash
# scripts/components/mcp/deploy.sh
# Runs INSIDE the mcp LXC. Idempotent. Installs 9 MCP servers as systemd services.

set -euo pipefail
: "${SOC_STATE_DIR:?}"; : "${SOC_COMPONENT:=mcp}"
STATE_FILE="${SOC_STATE_DIR}/state/${SOC_COMPONENT}.json"
SECRETS_DIR="${SOC_STATE_DIR}/secrets"
INSTALL_DIR="/opt/soc-mcp"
mkdir -p "${SOC_STATE_DIR}/state" "${SECRETS_DIR}" "${INSTALL_DIR}"

log() { printf '[mcp-deploy] %s\n' "$*"; }
write_failed() {
  jq -n --arg err "$1" '{component:"mcp",status:"failed",error:$err}' > "${STATE_FILE}"
  log "FAILED: $1"; exit 1
}
trap 'write_failed "aborted on line $LINENO"' ERR

# Server inventory: name | repo | port | env-key-list
# env-key-list documents what env vars integrate.sh will populate later.
declare -A SERVERS=(
  [wazuh]="https://github.com/solomonneas/wazuh-mcp.git|3001|WAZUH_URL,WAZUH_USER,WAZUH_PASSWORD"
  [thehive]="https://github.com/solomonneas/thehive-mcp.git|3002|THEHIVE_URL,THEHIVE_API_KEY"
  [cortex]="https://github.com/solomonneas/cortex-mcp.git|3003|CORTEX_URL,CORTEX_API_KEY"
  [misp]="https://github.com/solomonneas/misp-mcp.git|3004|MISP_URL,MISP_API_KEY"
  [zeek]="https://github.com/solomonneas/zeek-mcp.git|3005|ZEEK_LOG_DIR,ZEEK_LOG_FORMAT"
  [suricata]="https://github.com/solomonneas/suricata-mcp.git|3006|SURICATA_EVE_PATH"
  [mitre]="https://github.com/solomonneas/mitre-mcp.git|3007|MITRE_DATA_DIR"
  [rapid7]="https://github.com/solomonneas/rapid7-mcp.git|3008|RAPID7_URL,RAPID7_API_KEY"
  [sophos]="https://github.com/solomonneas/sophos-mcp.git|3009|SOPHOS_CLIENT_ID,SOPHOS_CLIENT_SECRET"
)

# Idempotency: every systemd unit active?
all_active=1
for name in "${!SERVERS[@]}"; do
  if ! systemctl is-active --quiet "soc-mcp-${name}" 2>/dev/null; then
    all_active=0; break
  fi
done

export DEBIAN_FRONTEND=noninteractive

if [[ "${all_active}" -eq 0 ]]; then
  log "installing deps"
  apt-get update -qq
  apt-get install -y -qq curl git ca-certificates jq

  if ! command -v node >/dev/null 2>&1 || (( "$(node -v | sed 's/[v.]/ /g' | awk '{print $1}')" < 20 )); then
    log "installing Node.js 20"
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y -qq nodejs
  fi
fi

IP="$(hostname -I | awk '{print $1}')"
ENDPOINTS_JSON='[]'

for name in wazuh thehive cortex misp zeek suricata mitre rapid7 sophos; do
  IFS='|' read -r repo port env_keys <<< "${SERVERS[$name]}"
  dest="${INSTALL_DIR}/${name}-mcp"

  # Token: persisted on first install, reused on idempotent re-runs
  token_file="${SECRETS_DIR}/mcp-${name}-token.txt"
  if [[ -f "${token_file}" ]]; then
    token="$(cat "${token_file}")"
  else
    token="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 40)"
    printf '%s' "${token}" > "${token_file}"
    chmod 600 "${token_file}"
  fi

  # Clone or update repo
  if [[ -d "${dest}/.git" ]]; then
    git -C "${dest}" fetch --quiet && git -C "${dest}" reset --quiet --hard origin/HEAD || true
  else
    git clone --quiet "${repo}" "${dest}"
  fi
  ( cd "${dest}" && npm install --silent && (npm run build --silent 2>/dev/null || true) )

  # systemd unit + env file
  env_file="/etc/soc-mcp/${name}.env"
  mkdir -p /etc/soc-mcp
  if [[ ! -f "${env_file}" ]]; then
    {
      echo "# Populated by integrate.sh after peer components come up."
      echo "PORT=${port}"
      echo "MCP_BEARER_TOKEN=${token}"
      echo "MCP_TRANSPORT=sse"
      # placeholders for the per-server env keys
      IFS=',' read -r -a keys <<< "${env_keys}"
      for k in "${keys[@]}"; do
        echo "${k}="
      done
    } > "${env_file}"
    chmod 600 "${env_file}"
  fi

  unit="/etc/systemd/system/soc-mcp-${name}.service"
  cat > "${unit}" <<UEOF
[Unit]
Description=SOC MCP server: ${name}
After=network.target

[Service]
Type=simple
EnvironmentFile=${env_file}
WorkingDirectory=${dest}
ExecStart=/usr/bin/node dist/index.js --transport sse --port \${PORT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UEOF

  systemctl daemon-reload
  systemctl enable --now "soc-mcp-${name}.service" >/dev/null 2>&1 || true

  ENDPOINTS_JSON="$(jq --arg n "${name}" --arg url "http://${IP}:${port}/sse" --arg tok "${token}" \
    '. + [{name:$n, url:$url, token:$tok}]' <<< "${ENDPOINTS_JSON}")"
done

jq -n \
  --arg ip "${IP}" \
  --argjson eps "${ENDPOINTS_JSON}" \
  '{
    component: "mcp",
    status: "deployed",
    host_ip: $ip,
    mcp_endpoints: $eps,
    services: ($eps | map("soc-mcp-" + .name))
  }' > "${STATE_FILE}"

log "deployed ${#SERVERS[@]} MCP servers"
trap - ERR
```

Commit: `components(mcp): add deploy.sh (9 servers, systemd, SSE transport)`.

---

## Task 33: `scripts/components/mcp/verify.sh`

**Files:**
- Create: `scripts/components/mcp/verify.sh`

Iterates each of `soc-mcp-{wazuh,thehive,cortex,misp,zeek,suricata,mitre,rapid7,sophos}.service` and checks `systemctl is-active`. For each port 3001-3009, attempts an HTTP GET on `http://localhost:<port>/sse` and confirms a response is returned (any 2xx/4xx is OK; means the server is listening). Exit 0 only if all 9 services are active AND all 9 ports respond.

Commit: `components(mcp): add verify.sh`.

---

## Task 34: `scripts/components/mcp/integrate.sh`

**Files:**
- Create: `scripts/components/mcp/integrate.sh`

This is THE wiring. For each peer in `state/` that's `status=deployed`, populate the corresponding `/etc/soc-mcp/<peer>.env` file with the peer's URL + API key, then restart the systemd service.

Runs on the Proxmox host. Reads peer state files, sshes to the MCP LXC via `pct exec`, writes the env files.

```bash
#!/usr/bin/env bash
# scripts/components/mcp/integrate.sh
# Runs on the Proxmox HOST. Reads peer component state, populates each
# MCP server's environment file, restarts each service.

set -euo pipefail
: "${SOC_STATE_DIR:?}"
log() { printf '[mcp-integrate] %s\n' "$*"; }

MCP_STATE="${SOC_STATE_DIR}/state/mcp.json"
[[ -f "${MCP_STATE}" ]] || { log "mcp state missing, skipping"; exit 0; }
mcp_status="$(jq -r '.status // empty' "${MCP_STATE}")"
[[ "${mcp_status}" == "deployed" ]] || { log "mcp status=${mcp_status}, skipping"; exit 0; }

mcp_vmid="$(jq -r '.lxc.vmid // empty' "${MCP_STATE}")"
[[ -n "${mcp_vmid}" ]] || { log "mcp has no VMID"; exit 0; }

write_env() {
  local server="$1"; shift
  # remaining args are KEY=value pairs
  local env_file="/etc/soc-mcp/${server}.env"
  local tmp
  tmp="$(mktemp)"
  pct exec "${mcp_vmid}" -- cat "${env_file}" > "${tmp}" 2>/dev/null || true
  for kv in "$@"; do
    key="${kv%%=*}"
    if grep -q "^${key}=" "${tmp}"; then
      sed -i "s|^${key}=.*|${kv}|" "${tmp}"
    else
      printf '%s\n' "${kv}" >> "${tmp}"
    fi
  done
  pct push "${mcp_vmid}" "${tmp}" "${env_file}"
  pct exec "${mcp_vmid}" -- chmod 600 "${env_file}"
  pct exec "${mcp_vmid}" -- systemctl restart "soc-mcp-${server}.service"
  rm -f "${tmp}"
}

# --- wazuh ---
ws="${SOC_STATE_DIR}/state/wazuh.json"
if [[ -f "${ws}" ]] && [[ "$(jq -r '.status' "${ws}")" == "deployed" ]]; then
  url="$(jq -r '.api_url' "${ws}")"
  pw="$(jq -r '.credentials.password' "${ws}")"
  write_env wazuh "WAZUH_URL=${url}" "WAZUH_USER=admin" "WAZUH_PASSWORD=${pw}"
  log "wired wazuh-mcp"
fi

# --- thehive + cortex ---
ts="${SOC_STATE_DIR}/state/thehive-cortex.json"
if [[ -f "${ts}" ]] && [[ "$(jq -r '.status' "${ts}")" == "deployed" ]]; then
  thu="$(jq -r '.thehive.url' "${ts}")"
  thk="$(jq -r '.thehive.api_key' "${ts}")"
  write_env thehive "THEHIVE_URL=${thu}" "THEHIVE_API_KEY=${thk}"
  log "wired thehive-mcp"

  cxu="$(jq -r '.cortex.url' "${ts}")"
  cxk="$(jq -r '.cortex.api_key' "${ts}")"
  write_env cortex "CORTEX_URL=${cxu}" "CORTEX_API_KEY=${cxk}"
  log "wired cortex-mcp"
fi

# --- misp ---
ms="${SOC_STATE_DIR}/state/misp.json"
if [[ -f "${ms}" ]] && [[ "$(jq -r '.status' "${ms}")" == "deployed" ]]; then
  url="$(jq -r '.url' "${ms}")"
  key="$(jq -r '.api_key' "${ms}")"
  write_env misp "MISP_URL=${url}" "MISP_API_KEY=${key}"
  log "wired misp-mcp"
fi

# --- zeek + suricata (log-based) ---
zs="${SOC_STATE_DIR}/state/zeek-suricata.json"
if [[ -f "${zs}" ]] && [[ "$(jq -r '.status' "${zs}")" == "deployed" ]]; then
  # Note: zeek and suricata MCP servers run on the mcp LXC and read LOCAL log files.
  # They need a bind-mount or NFS to the zeek-suricata LXC's log dirs. For Plan 2,
  # we set the env path; Plan 3 wires the actual bind-mount.
  zlog="$(jq -r '.zeek.log_dir' "${zs}")"
  write_env zeek "ZEEK_LOG_DIR=${zlog}" "ZEEK_LOG_FORMAT=json"
  log "wired zeek-mcp (path-only; bind-mount in Plan 3)"

  evepath="$(jq -r '.suricata.eve_path' "${zs}")"
  write_env suricata "SURICATA_EVE_PATH=${evepath}"
  log "wired suricata-mcp (path-only; bind-mount in Plan 3)"
fi

# --- mitre (no peer; just confirm env exists) ---
write_env mitre "MITRE_DATA_DIR=/opt/soc-mcp/mitre-mcp/data"
log "wired mitre-mcp"

# --- rapid7 + sophos: only wire if user supplied creds via env on the host ---
# These are commercial APIs; users provide creds via /etc/soc-stack/rapid7.env or sophos.env
if [[ -f /etc/soc-stack/rapid7.env ]]; then
  # shellcheck disable=SC1091
  . /etc/soc-stack/rapid7.env
  write_env rapid7 "RAPID7_URL=${RAPID7_URL:-}" "RAPID7_API_KEY=${RAPID7_API_KEY:-}"
  log "wired rapid7-mcp from /etc/soc-stack/rapid7.env"
fi
if [[ -f /etc/soc-stack/sophos.env ]]; then
  # shellcheck disable=SC1091
  . /etc/soc-stack/sophos.env
  write_env sophos "SOPHOS_CLIENT_ID=${SOPHOS_CLIENT_ID:-}" "SOPHOS_CLIENT_SECRET=${SOPHOS_CLIENT_SECRET:-}"
  log "wired sophos-mcp from /etc/soc-stack/sophos.env"
fi

log "mcp integration phase complete"
```

Commit: `components(mcp): add integrate.sh (wires 9 servers to peer endpoints)`.

---

## Task 35: `scripts/components/mcp/destroy.sh`

**Files:**
- Create: `scripts/components/mcp/destroy.sh`

Standard teardown.

Commit: `components(mcp): add destroy.sh teardown`.

---

# Phase G: Integration test assertions

## Task 36-40: Per-component integration assertion scripts

For each new component, create a `tests/integration/assert-<name>.sh` mirroring `assert-wazuh.sh` from Plan 1. Each script accepts `<result-json>` and verifies:
- Component status is deployed
- Each endpoint URL responds (HTTP 2xx/4xx, just confirming the service is listening)
- Credentials are populated

### Task 36: `tests/integration/assert-thehive-cortex.sh`

Verify TheHive (`/api/status` returns 200) and Cortex (`/api/status` returns 200). Confirm both passwords + API keys are non-empty in the result JSON.

Commit: `test(integration): add assert-thehive-cortex.sh`.

### Task 37: `tests/integration/assert-misp.sh`

Verify `https://<ip>/users/heartbeat` returns 200 (`-k` for self-signed). Confirm admin password + API key are non-empty.

Commit: `test(integration): add assert-misp.sh`.

### Task 38: `tests/integration/assert-zeek-suricata.sh`

Via `pct exec <vmid>`: `systemctl is-active zeek` AND `systemctl is-active suricata`. State JSON has `zeek.log_dir` and `suricata.eve_path` populated.

Commit: `test(integration): add assert-zeek-suricata.sh`.

### Task 39: `tests/integration/assert-dashboards.sh`

curl `http://<ip>/bro-hunter/` and `http://<ip>/playbook-forge/`, both return 2xx/3xx.

Commit: `test(integration): add assert-dashboards.sh`.

### Task 40: `tests/integration/assert-mcp.sh`

For each of the 9 ports (3001-3009), curl `http://<ip>:<port>/sse`. Each must return a response (2xx/4xx is fine; 5xx is failure). Verify the result JSON has `mcp_endpoints` with all 9 entries populated with non-empty `url` and `token`.

Commit: `test(integration): add assert-mcp.sh`.

---

## Task 41: `tests/integration/assert-all-integrations.sh`

**Files:**
- Create: `tests/integration/assert-all-integrations.sh`

Assert that cross-component wiring actually flows:

1. **Wazuh -> TheHive:** trigger a synthetic alert in Wazuh (write a test event to `/var/ossec/logs/alerts/alerts.log` with rule level 8). Within 60s, confirm `GET ${thehive_url}/api/v1/alert` (auth'd) returns an alert with source=Wazuh.
2. **TheHive <-> Cortex:** `GET ${thehive_url}/api/v1/config/cortex` returns the S3-CORTEX server entry.
3. **MISP -> Suricata:** confirm `/etc/cron.d/s3-misp-rules` exists in the zeek-suricata LXC AND `/etc/suricata/update.d/misp.conf` is non-empty.
4. **Zeek -> Wazuh:** in the zeek-suricata LXC, `systemctl is-active wazuh-agent` returns active.
5. **MCP env files populated:** each of `/etc/soc-mcp/{wazuh,thehive,cortex,misp,zeek,suricata}.env` in the mcp LXC has its respective key=value pairs non-empty.

Print pass/fail per integration. Exit 0 only if all 5 pass.

Commit: `test(integration): add assert-all-integrations.sh`.

---

# Phase H: proxmox-host smoke test

## Task 42: Full-stack minimal-preset smoke test on proxmox-host

This task is the integration gate for Plan 2. It deploys ALL 6 components to proxmox-host in the 9000-9099 VMID range, runs the integration assertions, and tears down.

- [ ] **Step 1: Rsync working tree to proxmox-host**

```bash
rsync -a --delete \
  --exclude='.git' \
  --exclude='tests/vendor/bats-core/.git' \
  --exclude='tests/vendor/bats-support/.git' \
  --exclude='tests/vendor/bats-assert/.git' \
  /home/user/repos/soc-stack/ proxmox-host:/root/soc-stack-test/
```

- [ ] **Step 2: Setup test env (multiple VMIDs)**

```bash
for c in wazuh thehive-cortex misp zeek-suricata dashboards mcp; do
  ssh proxmox-host "sudo bash /root/soc-stack-test/tests/integration/setup-test-env.sh ${c}"
done
ssh proxmox-host "cat /tmp/soc-stack-test/vmid-*.txt | sort -u"
```

NOTE: setup-test-env.sh allocates one VMID per call from the 9000-9099 range. We need 6 VMIDs.

The orchestrator's `--vmid-start` only sets the starting VMID; it allocates sequentially as it deploys. So we just need to find the LOWEST free VMID in the range and pass that as `--vmid-start`. The orchestrator handles the rest.

Simplification: skip the per-component setup-test-env and just check that 9000-9009 has at least 6 free slots.

```bash
ssh proxmox-host "sudo bash /root/soc-stack-test/tests/integration/setup-test-env.sh wazuh"
VMID_START=$(ssh proxmox-host "cat /tmp/soc-stack-test/vmid-wazuh.txt")
echo "starting VMID = ${VMID_START}"
```

- [ ] **Step 3: Real install, all 6 components, `--preset minimal` (90 min timeout)**

For the Bash tool call: `timeout=5400000` (90 minutes).

```bash
ssh proxmox-host "sudo bash /root/soc-stack-test/scripts/install.sh \
  --components wazuh,thehive-cortex,misp,zeek-suricata,dashboards,mcp \
  --preset minimal --bridge vmbr0 --storage local-lvm \
  --ip-mode dhcp --vmid-start ${VMID_START} \
  --state-dir /tmp/soc-stack-test \
  --json-out /tmp/soc-stack-test/result.json \
  --mcp-config-out /tmp/soc-stack-test/mcp-clients.json \
  --log-file /tmp/soc-stack-test/install.log 2>&1 | tail -200"
```

- [ ] **Step 4: Inspect result JSON**

```bash
ssh proxmox-host "jq . /tmp/soc-stack-test/result.json"
ssh proxmox-host "jq . /tmp/soc-stack-test/mcp-clients.json"
```

Expect 6 components in `.components[]`, each with `status=deployed`. `mcp-clients.json` should have all 9 servers in `mcpServers` and `raw_endpoints`.

- [ ] **Step 5: Per-component assertions**

```bash
for c in thehive-cortex misp zeek-suricata dashboards mcp; do
  ssh proxmox-host "bash /root/soc-stack-test/tests/integration/assert-${c}.sh /tmp/soc-stack-test/result.json"
done
ssh proxmox-host "bash /root/soc-stack-test/tests/integration/assert-wazuh.sh /tmp/soc-stack-test/result.json"
```

Each must print PASS.

- [ ] **Step 6: Integration assertion (cross-component wiring)**

```bash
ssh proxmox-host "bash /root/soc-stack-test/tests/integration/assert-all-integrations.sh /tmp/soc-stack-test/result.json"
```

Expect all 5 wires to pass.

- [ ] **Step 7: Idempotency**

```bash
ssh proxmox-host "time sudo bash /root/soc-stack-test/scripts/install.sh \
  --components wazuh,thehive-cortex,misp,zeek-suricata,dashboards,mcp \
  --preset minimal --bridge vmbr0 --storage local-lvm \
  --vmid-start ${VMID_START} \
  --state-dir /tmp/soc-stack-test --json-out /tmp/soc-stack-test/result.json 2>&1 | tail -20"
```

Expect under 2 minutes (mostly skip messages).

- [ ] **Step 8: Teardown**

```bash
ssh proxmox-host "sudo bash /root/soc-stack-test/tests/integration/destroy-test-env.sh --all"
ssh proxmox-host "pct list | awk 'NR>1 && \$1 >= 9000 && \$1 <= 9099 {print}' || echo 'clean'"
```

- [ ] **Step 9: Record PASS via empty commit**

```bash
git commit --allow-empty -m "test(integration): full-stack smoke test passes on test Proxmox host"
```

## If anything fails

Report BLOCKED to the controller. Plan 2 cannot be tagged until this passes.

---

# Phase I: Finalize

## Task 43: Update README with Plan 2 status

**Files:**
- Modify: `README.md`

In the existing `## Status` section, update Plan 2 from "next" to "this release" and Plan 1 to "shipped":

```markdown
## Status

A unified one-shot Proxmox installer is in active development. Plan 2 ships all 6 components deployable end-to-end with cross-component integrations. Legacy paths (Hyper-V scripts, per-tool LXC one-liners) still remain in the repo until Plan 3.

**Plan 1 (shipped 2026-05-15, v0.5.0):** Foundation + Wazuh deployment.

**Plan 2 (this release, v0.9.0):** All 6 components - wazuh, thehive-cortex, misp, zeek-suricata, dashboards, mcp - deployable via `scripts/install.sh --components all --preset minimal`. Cross-component integrations wired (Wazuh -> TheHive, TheHive <-> Cortex, MISP -> Suricata, Zeek -> Wazuh, MCP -> all peers). Manifest mode (`--manifest <path>`). See [the design spec](docs/superpowers/specs/2026-05-15-soc-stack-unification-design.md).

**Plan 3 (next):** Automated CI on Proxmox, README rewrite, deletion of legacy paths, v1.0.0 release.

---
```

Commit: `docs: update README with Plan 2 status`.

---

## Task 44: Full suite + shellcheck + tag v0.9.0

```bash
cd ~/repos/soc-stack
./tests/unit/run.sh   # Expect 78/78
shellcheck scripts/install.sh scripts/lib/*.sh scripts/components/*/*.sh tests/integration/*.sh install.sh
grep -Pn '[\x{2010}-\x{2015}]' scripts/install.sh scripts/lib/*.sh scripts/components/*/*.sh tests/integration/*.sh install.sh README.md || echo "no em dashes"

git tag -a v0.9.0 -m "All 6 components + cross-component integrations + manifest mode"
git log --oneline v0.9.0^..v0.9.0
```

If any check fails, STOP and BLOCK. Otherwise, tag is created.

---

## Definition of done

Plan 2 is complete when ALL of the following hold:

1. All 5 new components have the full 6-file module (manifest.jsonc + 5 .sh scripts), each shellcheck clean.
2. `scripts/lib/json-out.sh` has `emit_mcp_config()` with 3 bats tests passing.
3. `scripts/install.sh` supports `--manifest <path>` with 4 bats tests passing.
4. `scripts/install.sh` calls `emit_mcp_config` for `--mcp-config-out`.
5. `wazuh-install.sh -i` is preset-gated to minimal only.
6. `wazuh/integrate.sh` actually configures the TheHive webhook.
7. Full unit suite: 78/78 green.
8. proxmox-host smoke test: all 6 components deploy at `--preset minimal`, all 5 integrations wire, idempotency under 2min, clean teardown.
9. `git tag v0.9.0` exists.
10. Legacy paths (`stacks/`, `scripts/setup/`, `proxmox/`, `cloud-init/`, `reference/`, `specs/`) are STILL in place - Plan 3 deletes them.
