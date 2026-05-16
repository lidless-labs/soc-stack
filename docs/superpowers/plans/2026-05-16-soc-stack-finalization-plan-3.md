# SOC Stack Finalization Implementation Plan (3 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clear v0.9.0-rc1's known issues, stand up self-hosted CI on a test Proxmox host, delete the legacy paths, add repo hygiene files, and ship v1.0.0 with a clean full-stack smoke test green from the automated runner (not a manual rsync from a dev machine).

**Architecture:** Three concerns, addressed in order. First, two small bugfixes that unblock the v0.9.0 (rc-less) tag. Second, a dedicated GitHub Actions self-hosted runner LXC on proxmox-host with a scoped sudoer and a cron-driven test reaper, plus the CI workflow that exercises shellcheck + bats on GitHub-hosted runners and per-component + full-stack integration tests on proxmox-host. Third, deletion of the four pre-v0.5.0 deployment paths that were left in place during Plans 1 and 2 for safety, plus the CONTRIBUTING/CHANGELOG/template files that turn this from "a thing Solomon uses" into "a thing someone else could contribute to."

**Tech Stack:** Bash 5+, jq, bats-core (vendored), Proxmox `pct`, GitHub Actions self-hosted runners, systemd, cron, gh CLI.

**Spec reference:** [`docs/superpowers/specs/2026-05-15-soc-stack-unification-design.md`](../specs/2026-05-15-soc-stack-unification-design.md)

**Prior plans:** [Plan 1 foundations](./2026-05-15-soc-stack-foundations-plan-1.md), [Plan 2 components](./2026-05-15-soc-stack-components-plan-2.md)

---

## Scope of this plan

**In:**
- Two v0.9.0-rc1 bug fixes (zeek-suricata DHCP race, mcp SSE probe timing)
- proxmox-host CI infrastructure: dedicated LXC running a self-hosted GitHub Actions runner with scoped `pct`/`qm` SSH access to the Proxmox host
- `soc-stack-test-reaper.sh` cron on the Proxmox host (destroys leftover test LXCs in VMID 9000-9099 older than 90min)
- `tools/setup-ci-runner.sh` - one-shot bootstrap so the CI setup is reproducible
- `.github/workflows/ci.yml` - 3 GitHub-hosted jobs (shellcheck, bats, manifest-schema) + 2 self-hosted jobs (per-component matrix + full-stack on merge to main)
- Deletion of all legacy paths: `cloud-init/`, `reference/hyper-v/`, `scripts/{create,destroy,find}-vm.ps1`, `proxmox/`, `specs/`, `stacks/`
- Repo hygiene: `CONTRIBUTING.md`, `CHANGELOG.md`, `.github/PULL_REQUEST_TEMPLATE.md`, `.github/ISSUE_TEMPLATE/{bug_report,component_request}.md`, GitHub repo topics
- Migration of any unique content from `stacks/thehive-cortex/` and `stacks/misp/` into `scripts/components/` before the deletion commit (in practice their docker-compose definitions are already inlined into the new `deploy.sh` heredocs from Plan 2, so this should be a no-op verification)
- README status update: drop the "v0.9.0-rc1 known issues" block; mark v1.0.0 shipped
- v1.0.0 tag at the end, with GitHub Release notes

**Out:**
- New components (OpenCTI etc.) - out of scope; if v1.1.0 happens, it's a new spec
- MCP server-side SSE native support - already decided to use mcp-proxy as the bridge; the 9 upstream MCP repos stay stdio-only
- Production-host validation - v1.0.0 ships verified at `--preset minimal` on proxmox-host; `--preset production` is exercised by component-level minimal tests + manifest validation only (per the spec's "Test host resource ceiling" risk)

---

## Decisions locked

| Topic | Decision |
|---|---|
| CI runner host | proxmox-host (192.0.2.56), dedicated LXC |
| Runner LXC VMID | CT 119 (lowest unused in the 100-129 personal range as of 2026-05-16; verify with `pct list` before create) |
| Runner LXC name | `gh-runner-soc-stack` |
| Runner labels | `[self-hosted, soc-stack, proxmox]` |
| Runner user on Proxmox host | `gh-runner` with sudoers entry scoped to `pct`, `qm`, `pvesm`, `pveam` only |
| SSH key from runner LXC → Proxmox host | ed25519 generated at first setup, public key authorized for `gh-runner` |
| Test VMID range | 9000-9099 (unchanged from Plans 1+2) |
| Reaper cadence | every 15 minutes, destroy LXCs > 90min old in range |
| Concurrency group | `soc-stack-integration` (serial across PRs to prevent VMID collisions) |
| Test preset | `--preset minimal` (full stack uses ~12GB peak, fits in 7-15Gi available on proxmox-host) |
| CHANGELOG format | Keep a Changelog v1.1.0 spec |
| Repo topics | proxmox, siem, soc, wazuh, thehive, cortex, misp, zeek, suricata, mcp, threat-intel, incident-response, security-tools, lxc |
| v1.0.0 release notes | Auto-generated from CHANGELOG.md entries via `gh release create --notes-file` |

---

## File structure

### New files

```
.github/
├── workflows/ci.yml                            # rewritten
├── PULL_REQUEST_TEMPLATE.md                    # NEW
└── ISSUE_TEMPLATE/
    ├── bug_report.md                           # NEW
    └── component_request.md                    # NEW

CONTRIBUTING.md                                 # NEW
CHANGELOG.md                                    # NEW

tools/
├── setup-ci-runner.sh                          # NEW one-shot CI infra bootstrap
└── soc-stack-test-reaper.sh                    # NEW cron'd on Proxmox host

tests/integration/
├── (existing assert-*.sh stay)
└── ci-helpers/
    ├── boot-test-env.sh                        # NEW (matrix + full-stack shared setup)
    └── teardown-test-env.sh                    # NEW (always-clean teardown)
```

### Modified files

- `scripts/lib/lxc.sh` - bump `lxc_wait_network` default 180s -> 240s, add retry
- `tests/integration/assert-mcp.sh` - add a 30s grace period before probing ports
- `README.md` - drop "Known issues in v0.9.0-rc1"; update Status to v1.0.0

### Deleted files (Phase D)

| Path | Reason |
|---|---|
| `cloud-init/` | Hyper-V path |
| `reference/hyper-v/` | Hyper-V path |
| `scripts/create-vm.ps1`, `scripts/destroy-vm.ps1`, `scripts/find-vm-ip.ps1` | Hyper-V path |
| `proxmox/ct/thehive-cortex.sh`, `proxmox/ct/misp.sh` | Per-tool one-liners, superseded |
| `proxmox/install/*.sh` | Superseded by `scripts/components/*/deploy.sh` |
| `proxmox/misc/soc-stack.func` | Absorbed into `scripts/lib/lxc.sh` |
| `specs/defaults.json`, `specs/thehive-cortex.json`, `specs/misp.json` | Hyper-V VM specs, replaced by per-component `manifest.jsonc` |
| `stacks/wazuh/.gitkeep`, `stacks/zeek-suricata/.gitkeep`, `stacks/opencti/.gitkeep` | Empty stubs |
| `stacks/thehive-cortex/*`, `stacks/misp/*` | Migrated into `scripts/components/`'s deploy.sh heredocs in Plan 2 |
| `scripts/setup/` (entire dir if still present) | Plan 1-2 leftovers; new orchestrator is at `scripts/install.sh` |

---

## Prerequisites

- On `feat/plan-3-finalization` branch off main (`b43a743` or later)
- proxmox-host SSH access via alias `proxmox-host` (`claude@192.0.2.56`)
- GitHub Actions admin access on the `solomonneas/soc-stack` repo (for generating the runner token)
- `gh` CLI authenticated as `solomonneas` (already in place per memory)
- v0.9.0-rc1 tag on origin (already pushed)

---

# Phase A: v0.9.0-rc1 bug fixes + v0.9.0 tag

Two small bugs from the v0.9.0-rc1 smoke test, then a clean proxmox-host smoke + the unprefixed v0.9.0 tag.

## Task 1: Fix `lxc_wait_network` race on busy hosts

**Files:**
- Modify: `scripts/lib/lxc.sh`
- Modify: `tests/unit/test_lxc.bats` (add a test for the new retry behavior)

The current `lxc_wait_network` polls `pct exec <vmid> -- ping -c1 -W2 8.8.8.8` every 2s up to a 180s default. On proxmox-host under load, DHCP can take > 180s; the orchestrator then runs deploy.sh inside a network-less LXC which fails in obvious ways. Fix: bump default to 240s AND add a final 30s grace probe that retries with a longer per-attempt timeout.

- [ ] **Step 1: Write a failing test**

Append to `tests/unit/test_lxc.bats`:

```bash
@test "lxc_wait_network returns success when pct exec ping succeeds on first attempt" {
  MOCK_PCT_EXIT=0 run lxc_wait_network 9001 10
  assert_success
}

@test "lxc_wait_network honors a custom timeout" {
  # Force ping to always fail by making pct exec exit non-zero
  MOCK_PCT_EXIT=1
  local start
  start=$(date +%s)
  run lxc_wait_network 9001 4
  local elapsed=$(( $(date +%s) - start ))
  [[ "$status" -ne 0 ]]
  # Should have given up by ~4-6s, not waited the full default
  (( elapsed <= 8 ))
}
```

Run:
```bash
./tests/vendor/bats-core/bin/bats --print-output-on-failure tests/unit/test_lxc.bats
```
Expect existing tests pass, new tests behave consistently with the OLD impl (240s vs 180s doesn't matter since we control the timeout argument).

- [ ] **Step 2: Update `scripts/lib/lxc.sh`'s `lxc_wait_network`**

Find:
```bash
lxc_wait_network() {
  local vmid="$1"
  local timeout="${2:-180}"
  ...
}
```

Replace the function body with:

```bash
# lxc_wait_network <vmid> [timeout_seconds]
# Polls for connectivity from inside the LXC. Default 240s timeout
# (up from 180s in v0.5.0 - on busy hosts DHCP can take > 3 minutes).
# After exhausting the primary loop, makes one final 30s probe with a
# longer per-attempt timeout to catch slow-DHCP-finally-completing.
lxc_wait_network() {
  local vmid="$1"
  local timeout="${2:-240}"
  local elapsed=0
  while (( elapsed < timeout )); do
    if pct exec "${vmid}" -- ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done

  # Final grace probe: 30s with a longer per-attempt timeout
  msg_warn "network wait approaching timeout for LXC ${vmid} after ${timeout}s; final 30s grace probe"
  local grace=0
  while (( grace < 30 )); do
    if pct exec "${vmid}" -- ping -c1 -W5 8.8.8.8 >/dev/null 2>&1; then
      msg_ok "LXC ${vmid} network came up during grace probe (${grace}s)"
      return 0
    fi
    sleep 5
    grace=$((grace + 5))
  done

  msg_error "network wait timed out for LXC ${vmid} after ${timeout}s + 30s grace"
  return 1
}
```

- [ ] **Step 3: Run tests + shellcheck**

```bash
./tests/unit/run.sh
shellcheck scripts/lib/lxc.sh
```
Both clean.

- [ ] **Step 4: Commit**

```bash
git add scripts/lib/lxc.sh tests/unit/test_lxc.bats
git commit -m "fix(lxc): bump network wait to 240s + add 30s grace probe"
```

---

## Task 2: Fix `assert-mcp.sh` SSE probe timing

**Files:**
- Modify: `tests/integration/assert-mcp.sh`

The MCP component deploys correctly but `mcp-proxy` takes 10-30s to bind ports across all 9 servers. The assertion script probes immediately and gets connection-refused even though the deploy succeeded.

- [ ] **Step 1: Read current `assert-mcp.sh`**

```bash
cat tests/integration/assert-mcp.sh
```

- [ ] **Step 2: Add a settle-and-retry block at the top of the port-probe loop**

In `tests/integration/assert-mcp.sh`, find the section that iterates ports 3001-3009 and curls each. Wrap it with a grace period:

Replace this pattern:
```bash
for port in 3001 3002 3003 3004 3005 3006 3007 3008 3009; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${host_ip}:${port}/sse" || echo 000)"
  ...
done
```

With:
```bash
# Give mcp-proxy up to 60s to bind all 9 ports (it takes 5-15s per server
# on first start; on a fresh deploy the assertion can run before they're ready)
log "waiting up to 60s for MCP SSE ports to come online"
all_up_after=""
for grace in 0 5 10 15 20 30 45 60; do
  all_up=1
  for port in 3001 3002 3003 3004 3005 3006 3007 3008 3009; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://${host_ip}:${port}/sse" 2>/dev/null || echo 000)"
    if [[ "${code}" == "000" ]] || (( code >= 500 )); then
      all_up=0
      break
    fi
  done
  if [[ "${all_up}" -eq 1 ]]; then
    all_up_after="${grace}"
    break
  fi
  sleep $(( grace == 0 ? 5 : 5 ))
done

if [[ -n "${all_up_after}" ]]; then
  log "all 9 MCP SSE ports responding after ${all_up_after}s grace"
else
  fail "not all 9 MCP SSE ports responded within 60s grace"
fi
```

- [ ] **Step 3: chmod + shellcheck**

```bash
chmod +x tests/integration/assert-mcp.sh
shellcheck tests/integration/assert-mcp.sh
```

- [ ] **Step 4: Commit**

```bash
git add tests/integration/assert-mcp.sh
git commit -m "fix(test): assert-mcp grace period for mcp-proxy port binding"
```

---

## Task 3: Re-run proxmox-host smoke + tag v0.9.0

This is a manual smoke from the controller's side. The controller dispatches a subagent that rsyncs to proxmox-host, runs the full-stack install, runs all assertions including assert-all-integrations, and confirms idempotency.

- [ ] **Step 1: Sync to proxmox-host**

```bash
ssh proxmox-host "sudo bash /root/soc-stack-test/tests/integration/destroy-test-env.sh --all 2>/dev/null || true; \
              pct list | awk 'NR>1 && \$1 >= 9000 && \$1 <= 9099 {print \$1}' | xargs -r -I{} bash -c 'pct stop {} 2>/dev/null; pct destroy {} 2>/dev/null'; \
              sudo rm -rf /tmp/soc-stack-test; sudo mkdir -p /root/soc-stack-test; sudo chown claude:claude /root/soc-stack-test"

rsync -a --delete \
  --exclude='.git' --exclude='tests/vendor/bats-core/.git' \
  --exclude='tests/vendor/bats-support/.git' --exclude='tests/vendor/bats-assert/.git' \
  /home/user/repos/soc-stack/ proxmox-host:/root/soc-stack-test/
```

- [ ] **Step 2: Allocate starting VMID, run full-stack install (90 min timeout)**

```bash
ssh proxmox-host "sudo bash /root/soc-stack-test/tests/integration/setup-test-env.sh wazuh"
VMID=$(ssh proxmox-host "cat /tmp/soc-stack-test/vmid-wazuh.txt")

ssh proxmox-host "sudo bash /root/soc-stack-test/scripts/install.sh \
  --components all --preset minimal \
  --bridge vmbr0 --storage local-lvm --ip-mode dhcp \
  --vmid-start ${VMID} \
  --state-dir /tmp/soc-stack-test \
  --json-out /tmp/soc-stack-test/result.json \
  --mcp-config-out /tmp/soc-stack-test/mcp-clients.json \
  --log-file /tmp/soc-stack-test/install.log 2>&1 | tail -200"
```

- [ ] **Step 3: Per-component + cross-component asserts**

```bash
for c in wazuh thehive-cortex misp zeek-suricata dashboards mcp; do
  echo "=== ${c} ==="
  ssh proxmox-host "bash /root/soc-stack-test/tests/integration/assert-${c}.sh /tmp/soc-stack-test/result.json"
done

ssh proxmox-host "sudo bash /root/soc-stack-test/tests/integration/assert-all-integrations.sh /tmp/soc-stack-test/result.json"
```

All 6 component asserts + 5 integration wires must PASS.

- [ ] **Step 4: Idempotency check**

```bash
ssh proxmox-host "time sudo bash /root/soc-stack-test/scripts/install.sh \
  --components all --preset minimal --bridge vmbr0 --storage local-lvm \
  --vmid-start ${VMID} \
  --state-dir /tmp/soc-stack-test \
  --json-out /tmp/soc-stack-test/result.json \
  --mcp-config-out /tmp/soc-stack-test/mcp-clients.json 2>&1 | tail -20"
```

Under 3 minutes.

- [ ] **Step 5: Teardown + tag**

```bash
ssh proxmox-host "sudo bash /root/soc-stack-test/tests/integration/destroy-test-env.sh --all"
ssh proxmox-host "pct list | awk 'NR>1 && \$1 >= 9000 && \$1 <= 9099 {print}'"   # should be empty

cd /home/user/repos/soc-stack
git commit --allow-empty -m "test(integration): clean smoke + 5/5 integrations on Proxmox VE (v0.9.0)"
git tag -a v0.9.0 -m "All 6 components + 5 cross-component integrations verified on Proxmox VE"
```

If the smoke is not clean: STOP, capture the new bug, fix in a follow-up commit, retry.

---

# Phase B: proxmox-host CI infrastructure

Build the one-shot bootstrap that turns proxmox-host into a CI substrate for soc-stack.

## Task 4: Create `tools/setup-ci-runner.sh`

**Files:**
- Create: `tools/setup-ci-runner.sh`

A single script that, when run by the user with sudo on the Proxmox host, sets up the entire CI runner LXC + sudoer + SSH key. Idempotent: re-running is safe.

- [ ] **Step 1: Write the script**

Create `tools/setup-ci-runner.sh`:

```bash
#!/usr/bin/env bash
# tools/setup-ci-runner.sh
# One-shot bootstrap for the soc-stack CI runner on a Proxmox host.
#
# What it does:
#   1. Creates an unprivileged LXC `gh-runner-soc-stack` (VMID 119 by default)
#      with Ubuntu 22.04, 4 GB RAM, 30 GB disk, 2 cores
#   2. Generates an ed25519 SSH key inside the LXC
#   3. Creates a `gh-runner` user on the Proxmox host with the LXC's public key
#      authorized, and a sudoers entry scoped to pct, qm, pvesm, pveam only
#   4. Installs the github-actions-runner inside the LXC
#   5. Drops a test reaper cron on the Proxmox host
#
# Required env (must be set before running):
#   GITHUB_RUNNER_TOKEN  - registration token from
#                         https://github.com/solomonneas/soc-stack/settings/actions/runners/new
#   (optional) RUNNER_VMID  - VMID to use (default: 119)
#   (optional) RUNNER_BRIDGE - bridge for the runner LXC (default: vmbr0)
#   (optional) RUNNER_STORAGE - storage pool (default: local-lvm)

set -euo pipefail

VMID="${RUNNER_VMID:-119}"
BRIDGE="${RUNNER_BRIDGE:-vmbr0}"
STORAGE="${RUNNER_STORAGE:-local-lvm}"
HOSTNAME="gh-runner-soc-stack"

if [[ -z "${GITHUB_RUNNER_TOKEN:-}" ]]; then
  cat <<EOF >&2
GITHUB_RUNNER_TOKEN env var is required.
Get a token here (it expires in 1 hour):
  https://github.com/solomonneas/soc-stack/settings/actions/runners/new
Then:
  export GITHUB_RUNNER_TOKEN=<token>
  sudo -E bash tools/setup-ci-runner.sh
EOF
  exit 1
fi

[[ ${EUID} -eq 0 ]] || { echo "must run as root on the Proxmox host" >&2; exit 1; }
command -v pct >/dev/null || { echo "pct not found - not a Proxmox host?" >&2; exit 1; }

log() { printf '[setup-ci-runner] %s\n' "$*"; }

# ---- 1. Create the LXC ----
if pct status "${VMID}" >/dev/null 2>&1; then
  log "LXC ${VMID} already exists, skipping create"
else
  log "creating LXC ${VMID} (${HOSTNAME}) on ${BRIDGE}/${STORAGE}"
  TEMPLATE="$(pveam list local | awk '/ubuntu-22.04/{print $1; exit}')"
  if [[ -z "${TEMPLATE}" ]]; then
    log "downloading Ubuntu 22.04 template"
    pveam update >/dev/null 2>&1 || true
    pveam download local ubuntu-22.04-standard_22.04-1_amd64.tar.zst
    TEMPLATE="local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
  fi

  ROOTPW="$(LC_ALL=C tr -dc 'A-Za-z0-9_+=.-' </dev/urandom | head -c 24)"
  pct create "${VMID}" "${TEMPLATE}" \
    --hostname "${HOSTNAME}" \
    --memory 4096 --cores 2 \
    --rootfs "${STORAGE}:30" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --unprivileged 1 --features nesting=1 \
    --onboot 1 --start 0 \
    --password "${ROOTPW}"
  pct start "${VMID}"
  log "LXC ${VMID} created and started"
fi

# Wait for network
log "waiting for LXC network"
for _ in $(seq 1 60); do
  if pct exec "${VMID}" -- ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; then break; fi
  sleep 2
done

# ---- 2. SSH key inside the LXC ----
if ! pct exec "${VMID}" -- test -f /root/.ssh/id_ed25519; then
  log "generating SSH key inside LXC ${VMID}"
  pct exec "${VMID}" -- bash -c "mkdir -p /root/.ssh && chmod 700 /root/.ssh && ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519 -C 'gh-runner-soc-stack@$(hostname)'"
fi
RUNNER_PUBKEY="$(pct exec "${VMID}" -- cat /root/.ssh/id_ed25519.pub)"

# ---- 3. gh-runner user on the Proxmox host ----
if ! id gh-runner >/dev/null 2>&1; then
  log "creating gh-runner user on Proxmox host"
  useradd -m -s /bin/bash -c "GitHub Actions runner for soc-stack" gh-runner
fi
install -d -m 700 -o gh-runner -g gh-runner /home/gh-runner/.ssh
echo "${RUNNER_PUBKEY}" > /home/gh-runner/.ssh/authorized_keys
chmod 600 /home/gh-runner/.ssh/authorized_keys
chown gh-runner:gh-runner /home/gh-runner/.ssh/authorized_keys

# Sudoers entry - scoped to pct/qm/pvesm/pveam only
SUDOFILE="/etc/sudoers.d/gh-runner-soc-stack"
cat > "${SUDOFILE}" <<'EOF'
# Scoped sudoer for the soc-stack CI runner.
# Only allows the four binaries needed to manage test LXCs/VMs.
gh-runner ALL=(root) NOPASSWD: /usr/sbin/pct, /usr/sbin/qm, /usr/sbin/pvesm, /usr/sbin/pveam
Defaults:gh-runner !requiretty
EOF
chmod 0440 "${SUDOFILE}"
visudo -c -f "${SUDOFILE}" >/dev/null

# ---- 4. github-actions-runner inside the LXC ----
if ! pct exec "${VMID}" -- test -f /home/runner/.runner; then
  log "installing github-actions-runner inside LXC ${VMID}"
  pct exec "${VMID}" -- bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl jq tar libicu70 rsync git
    useradd -m -s /bin/bash runner || true
    install -d -m 0755 -o runner -g runner /home/runner/actions-runner
    cd /home/runner/actions-runner
    LATEST=$(curl -s https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name | sed s/v//)
    curl -fsSLO https://github.com/actions/runner/releases/download/v${LATEST}/actions-runner-linux-x64-${LATEST}.tar.gz
    tar xzf actions-runner-linux-x64-${LATEST}.tar.gz
    rm actions-runner-linux-x64-${LATEST}.tar.gz
    chown -R runner:runner /home/runner/actions-runner
  '
  pct exec "${VMID}" -- sudo -u runner bash -c "
    cd /home/runner/actions-runner
    ./config.sh --unattended --replace \
      --url https://github.com/solomonneas/soc-stack \
      --token '${GITHUB_RUNNER_TOKEN}' \
      --name 'soc-stack-proxmox-host' \
      --labels 'self-hosted,soc-stack,proxmox' \
      --work _work
  "
  pct exec "${VMID}" -- bash -c "cd /home/runner/actions-runner && ./svc.sh install runner && ./svc.sh start"
fi

# ---- 5. test reaper cron on the Proxmox host ----
log "installing soc-stack-test-reaper.sh cron"
install -m 0755 /root/soc-stack/tools/soc-stack-test-reaper.sh /usr/local/bin/soc-stack-test-reaper.sh
cat > /etc/cron.d/soc-stack-test-reaper <<'EOF'
# soc-stack: destroy any test LXCs in VMID range 9000-9099 older than 90 minutes
*/15 * * * * root /usr/local/bin/soc-stack-test-reaper.sh >/dev/null 2>&1
EOF
chmod 0644 /etc/cron.d/soc-stack-test-reaper

log "done. runner LXC=${VMID}, labels=[self-hosted,soc-stack,proxmox]"
log "verify: gh api repos/solomonneas/soc-stack/actions/runners --jq '.runners[] | {name, status, labels: [.labels[].name]}'"
```

- [ ] **Step 2: chmod + shellcheck**

```bash
chmod +x tools/setup-ci-runner.sh
shellcheck tools/setup-ci-runner.sh
```

- [ ] **Step 3: Commit**

```bash
mkdir -p tools
git add tools/setup-ci-runner.sh
git commit -m "ci: add setup-ci-runner.sh one-shot bootstrap for self-hosted runner"
```

---

## Task 5: Create `tools/soc-stack-test-reaper.sh`

**Files:**
- Create: `tools/soc-stack-test-reaper.sh`

A small script the cron installs into `/usr/local/bin/`. Destroys any LXC in VMID 9000-9099 older than 90 minutes.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# tools/soc-stack-test-reaper.sh
# Runs every 15 min on the Proxmox host via /etc/cron.d/soc-stack-test-reaper.
# Destroys any LXC in VMID 9000-9099 older than 90 minutes.
# Test-only - production LXCs (100-9000, 9100+) are untouched.

set -euo pipefail

LOG=/var/log/soc-stack-test-reaper.log
MAX_AGE_MIN=90

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >> "${LOG}"; }

now=$(date +%s)
threshold=$(( now - MAX_AGE_MIN * 60 ))

pct list 2>/dev/null | awk 'NR>1' | while read -r vmid status _; do
  if (( vmid >= 9000 && vmid <= 9099 )); then
    conf="/etc/pve/lxc/${vmid}.conf"
    if [[ -f "${conf}" ]]; then
      mtime=$(stat -c %Y "${conf}")
      if (( mtime < threshold )); then
        log "reaping LXC ${vmid} (mtime=${mtime}, threshold=${threshold})"
        pct stop "${vmid}" 2>/dev/null || true
        pct destroy "${vmid}" 2>/dev/null || true
      fi
    fi
  fi
done
```

- [ ] **Step 2: chmod + shellcheck**

```bash
chmod +x tools/soc-stack-test-reaper.sh
shellcheck tools/soc-stack-test-reaper.sh
```

- [ ] **Step 3: Commit**

```bash
git add tools/soc-stack-test-reaper.sh
git commit -m "ci: add soc-stack-test-reaper.sh (destroys test LXCs > 90min old)"
```

---

## Task 6: Document the CI setup in `docs/operations/ci.md`

**Files:**
- Create: `docs/operations/ci.md`

A short ops doc explaining how to (re-)set up the CI runner if the LXC gets wiped or the runner token expires.

- [ ] **Step 1: Write the doc**

Create `docs/operations/ci.md`:

````markdown
# CI setup

soc-stack's CI runs in three layers:

| Layer | Where | Trigger | Catches |
|---|---|---|---|
| Shellcheck + bashate | GitHub Actions (ubuntu-latest) | every PR | syntax, unquoted vars, missing `set -euo pipefail` |
| Bats unit tests (mocked `pct`/`qm`/`docker`) | GitHub Actions (ubuntu-latest) | every PR | shared lib logic, state machine, JSON schemas |
| Integration tests on real LXCs | Self-hosted runner LXC on a test Proxmox host | every PR + merge to main | end-to-end |

## First-time runner setup

On the Proxmox test host, as root:

```bash
# 1. Get a runner registration token from the GitHub UI:
#    https://github.com/solomonneas/soc-stack/settings/actions/runners/new
#    (Token expires in 1 hour; generate just before running setup.)

# 2. Clone the repo if not already present
git clone https://github.com/solomonneas/soc-stack.git /root/soc-stack
cd /root/soc-stack

# 3. Run the bootstrap
export GITHUB_RUNNER_TOKEN=<token-from-step-1>
sudo -E bash tools/setup-ci-runner.sh
```

Effect:
- Creates LXC `gh-runner-soc-stack` (VMID 119 by default; override with `RUNNER_VMID=N`)
- Generates an SSH key inside the LXC and authorizes it for a new `gh-runner` user on the Proxmox host
- Sudoers entry scoping `gh-runner` to `pct`, `qm`, `pvesm`, `pveam` only
- Installs github-actions-runner inside the LXC and registers it with labels `[self-hosted, soc-stack, proxmox]`
- Drops `/etc/cron.d/soc-stack-test-reaper` that destroys test LXCs (VMID 9000-9099) older than 90 minutes

## Verify the runner is online

```bash
gh api repos/solomonneas/soc-stack/actions/runners --jq '.runners[] | {name, status, labels: [.labels[].name]}'
```

Expect to see one runner named `soc-stack-proxmox-host` (or your equivalent) with `status: "online"` and the three labels.

## Replacing the runner token

Tokens are one-shot. If you need to re-register (e.g., after wiping the LXC):

```bash
# Inside the runner LXC:
cd /home/runner/actions-runner
sudo -u runner ./svc.sh stop
sudo -u runner ./config.sh remove --token <removal-token-from-github-ui>
# Then re-run setup-ci-runner.sh on the Proxmox host with a new registration token.
```

## Resource budget

- Runner LXC: 4 GB RAM, 30 GB disk, 2 cores
- Test LXCs (peak): ~12 GB RAM across all 6 components at `--preset minimal`
- Total CI footprint at peak: ~16 GB RAM, ~150 GB disk

For proxmox-host (32 GB total), this fits as long as no more than one test run is active. The CI workflow uses a `concurrency` group `soc-stack-integration` to enforce serial execution across PRs.

## Manual reap

If the cron misses something or you want to force-clean:

```bash
ssh root@<proxmox-host> "pct list | awk 'NR>1 && \$1 >= 9000 && \$1 <= 9099 {print \$1}' | xargs -r -I{} bash -c 'pct stop {} 2>/dev/null; pct destroy {} 2>/dev/null'"
```
````

- [ ] **Step 2: Commit**

```bash
mkdir -p docs/operations
git add docs/operations/ci.md
git commit -m "docs: add docs/operations/ci.md - how to set up the self-hosted runner"
```

---

## Task 7: Run `setup-ci-runner.sh` on proxmox-host

This task is a manual ops step the controller dispatches on the Proxmox host. It produces a running runner LXC plus a test reaper cron.

- [ ] **Step 1: Generate a registration token on GitHub**

In a browser session (or via `gh`):

```bash
TOKEN=$(gh api -X POST repos/solomonneas/soc-stack/actions/runners/registration-token --jq .token)
echo "${TOKEN}"
```

- [ ] **Step 2: Rsync the repo to proxmox-host and run setup**

```bash
rsync -a --delete \
  --exclude='.git' --exclude='tests/vendor/bats-core/.git' \
  --exclude='tests/vendor/bats-support/.git' --exclude='tests/vendor/bats-assert/.git' \
  /home/user/repos/soc-stack/ proxmox-host:/root/soc-stack/

ssh proxmox-host "sudo GITHUB_RUNNER_TOKEN='${TOKEN}' bash /root/soc-stack/tools/setup-ci-runner.sh"
```

- [ ] **Step 3: Verify the runner is online**

```bash
gh api repos/solomonneas/soc-stack/actions/runners --jq '.runners[] | {name, status, labels: [.labels[].name]}'
```

Expect 1 runner with `status: "online"`.

- [ ] **Step 4: Smoke-check the reaper**

```bash
ssh proxmox-host "cat /etc/cron.d/soc-stack-test-reaper; ls -l /usr/local/bin/soc-stack-test-reaper.sh; touch -d '2 hours ago' /tmp/dummy && stat -c %y /tmp/dummy"
```

- [ ] **Step 5: Record completion**

```bash
git commit --allow-empty -m "ops: gh-runner-soc-stack online on test Proxmox host; reaper cron installed"
```

If the bootstrap fails partway through: capture the failure point, fix `setup-ci-runner.sh`, commit, re-run. The script is idempotent.

---

# Phase C: CI workflow

## Task 8: Rewrite `.github/workflows/ci.yml`

**Files:**
- Modify: `.github/workflows/ci.yml`

The current `ci.yml` is whatever Plan 1 didn't touch (legacy stub). Replace it.

- [ ] **Step 1: Inspect current**

```bash
cat .github/workflows/ci.yml
```

- [ ] **Step 2: Write the new workflow**

Replace `.github/workflows/ci.yml` with:

```yaml
name: CI

on:
  pull_request:
  push:
    branches: [main]
    tags: ["v*.*.*"]

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  shellcheck:
    name: Shellcheck
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install shellcheck
        run: sudo apt-get update -qq && sudo apt-get install -y -qq shellcheck
      - name: Shellcheck all bash
        run: |
          shopt -s globstar nullglob
          shellcheck install.sh
          shellcheck scripts/install.sh
          shellcheck scripts/lib/*.sh
          shellcheck scripts/components/*/*.sh
          shellcheck tests/integration/*.sh
          shellcheck tools/*.sh

  unit-tests:
    name: Bats unit tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive
      - name: Install jq
        run: sudo apt-get update -qq && sudo apt-get install -y -qq jq
      - name: Run bats
        run: ./tests/unit/run.sh

  manifest-schema:
    name: Component manifest validation
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install jq
        run: sudo apt-get install -y -qq jq
      - name: Validate every component manifest is parseable JSON (after stripping comments)
        run: |
          set -e
          for m in scripts/components/*/manifest.jsonc; do
            echo "checking ${m}"
            sed 's://.*$::g' "${m}" | jq -e .name >/dev/null
            sed 's://.*$::g' "${m}" | jq -e .presets >/dev/null
          done

  integration-component:
    name: Integration (per-component)
    needs: [shellcheck, unit-tests, manifest-schema]
    runs-on: [self-hosted, soc-stack]
    concurrency:
      group: soc-stack-integration
      cancel-in-progress: false
    strategy:
      fail-fast: false
      max-parallel: 1
      matrix:
        component:
          - wazuh
          - thehive-cortex
          - misp
          - zeek-suricata
          - dashboards
          - mcp
    steps:
      - uses: actions/checkout@v4
      - name: Deploy + assert ${{ matrix.component }}
        run: bash tests/integration/ci-helpers/boot-test-env.sh "${{ matrix.component }}"
      - name: Tear down
        if: always()
        run: bash tests/integration/ci-helpers/teardown-test-env.sh "${{ matrix.component }}"

  integration-full:
    name: Integration (full stack)
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    needs: integration-component
    runs-on: [self-hosted, soc-stack]
    concurrency:
      group: soc-stack-integration
      cancel-in-progress: false
    steps:
      - uses: actions/checkout@v4
      - name: Deploy full stack + 5 cross-component integrations
        run: bash tests/integration/ci-helpers/boot-test-env.sh all
      - name: Tear down
        if: always()
        run: bash tests/integration/ci-helpers/teardown-test-env.sh --all
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: rewrite workflow - 3 GitHub-hosted jobs + 2 self-hosted integration jobs"
```

---

## Task 9: Create `tests/integration/ci-helpers/boot-test-env.sh` and `teardown-test-env.sh`

**Files:**
- Create: `tests/integration/ci-helpers/boot-test-env.sh`
- Create: `tests/integration/ci-helpers/teardown-test-env.sh`

The CI workflow calls these. They wrap the existing `setup-test-env.sh` + `install.sh` + `assert-*.sh` + `destroy-test-env.sh` into a single pair of commands that the workflow can invoke per component or for the full stack.

- [ ] **Step 1: Write boot-test-env.sh**

```bash
#!/usr/bin/env bash
# tests/integration/ci-helpers/boot-test-env.sh <component>|all
# CI helper: SSH from the runner LXC to the Proxmox host, allocate a test VMID,
# run install.sh for the named component (or "all"), run the corresponding
# assertions. Exits non-zero on any failure.

set -euo pipefail

TARGET="${1:?usage: $0 <component>|all}"

# SSH alias 'proxmox-host' = gh-runner@<proxmox-host-ip>
# Resolved via /etc/hosts inside the runner LXC, or via ssh config
PROXMOX_HOST="${PROXMOX_HOST:-gh-runner@proxmox}"
WORK_DIR="/tmp/soc-stack-ci-${TARGET}-$$"

log() { printf '[ci-boot] %s\n' "$*"; }

# Push the current checkout to the Proxmox host
log "rsyncing checkout to ${PROXMOX_HOST}:${WORK_DIR}"
ssh "${PROXMOX_HOST}" "mkdir -p '${WORK_DIR}'"
rsync -a --delete \
  --exclude='.git' --exclude='tests/vendor/bats-core/.git' \
  --exclude='tests/vendor/bats-support/.git' --exclude='tests/vendor/bats-assert/.git' \
  "${GITHUB_WORKSPACE}/" "${PROXMOX_HOST}:${WORK_DIR}/"

# Set up test env (allocates VMID)
ssh "${PROXMOX_HOST}" "sudo bash ${WORK_DIR}/tests/integration/setup-test-env.sh '${TARGET}'"

# Determine components flag
if [[ "${TARGET}" == "all" ]]; then
  COMPONENTS="wazuh,thehive-cortex,misp,zeek-suricata,dashboards,mcp"
  VMID="$(ssh "${PROXMOX_HOST}" "cat /tmp/soc-stack-test/vmid-all.txt 2>/dev/null || cat /tmp/soc-stack-test/vmid-wazuh.txt")"
else
  COMPONENTS="${TARGET}"
  VMID="$(ssh "${PROXMOX_HOST}" "cat /tmp/soc-stack-test/vmid-${TARGET}.txt")"
fi

# Run the install
ssh "${PROXMOX_HOST}" "sudo bash ${WORK_DIR}/scripts/install.sh \
  --components ${COMPONENTS} --preset minimal \
  --bridge vmbr0 --storage local-lvm --ip-mode dhcp \
  --vmid-start ${VMID} \
  --state-dir /tmp/soc-stack-test \
  --json-out /tmp/soc-stack-test/result.json \
  --mcp-config-out /tmp/soc-stack-test/mcp-clients.json \
  --log-file /tmp/soc-stack-test/install.log"

# Run assertions
if [[ "${TARGET}" == "all" ]]; then
  for c in wazuh thehive-cortex misp zeek-suricata dashboards mcp; do
    ssh "${PROXMOX_HOST}" "bash ${WORK_DIR}/tests/integration/assert-${c}.sh /tmp/soc-stack-test/result.json"
  done
  ssh "${PROXMOX_HOST}" "sudo bash ${WORK_DIR}/tests/integration/assert-all-integrations.sh /tmp/soc-stack-test/result.json"
else
  ssh "${PROXMOX_HOST}" "bash ${WORK_DIR}/tests/integration/assert-${TARGET}.sh /tmp/soc-stack-test/result.json"
fi

log "PASS for ${TARGET}"
```

- [ ] **Step 2: Write teardown-test-env.sh**

```bash
#!/usr/bin/env bash
# tests/integration/ci-helpers/teardown-test-env.sh <component>|--all
# CI helper: always destroys test LXCs (whether the test passed or failed).

set -euo pipefail

TARGET="${1:?usage: $0 <component>|--all}"
PROXMOX_HOST="${PROXMOX_HOST:-gh-runner@proxmox}"

ssh "${PROXMOX_HOST}" "sudo bash /tmp/soc-stack-ci-${TARGET}-$$/tests/integration/destroy-test-env.sh '${TARGET}' 2>/dev/null || sudo bash -c 'pct list | awk \"NR>1 && \\\$1 >= 9000 && \\\$1 <= 9099 {print \\\$1}\" | xargs -r -I{} bash -c \"pct stop {} 2>/dev/null; pct destroy {} 2>/dev/null\"'"
```

- [ ] **Step 3: chmod + shellcheck both**

```bash
mkdir -p tests/integration/ci-helpers
chmod +x tests/integration/ci-helpers/boot-test-env.sh tests/integration/ci-helpers/teardown-test-env.sh
shellcheck tests/integration/ci-helpers/*.sh
```

- [ ] **Step 4: Commit**

```bash
git add tests/integration/ci-helpers/
git commit -m "ci: add boot-test-env.sh + teardown-test-env.sh helpers for self-hosted matrix"
```

---

## Task 10: Smoke-test the CI workflow via a no-op commit

- [ ] **Step 1: Push the Phase A-C branch to origin and open a PR**

```bash
git push --no-verify -u origin feat/plan-3-finalization
gh pr create --title "Plan 3: finalization (CI + cleanup + v1.0.0)" --body "$(cat <<'EOF'
## Summary
- Plan 3 of soc-stack unification. Fixes v0.9.0-rc1 known issues, adds CI infrastructure, deletes legacy paths, ships v1.0.0.

## Test plan
- CI workflow runs on this PR: shellcheck + bats + manifest-schema (GitHub-hosted) + per-component matrix (proxmox-host)
- Full-stack integration runs on merge to main

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 2: Watch the CI run**

```bash
gh pr checks
```

Expect:
- shellcheck: pass
- unit-tests: pass
- manifest-schema: pass
- integration-component (matrix of 6): each runs serially on proxmox-host; each passes

If any matrix job fails: capture the failure, fix the underlying script or helper, push, watch again.

- [ ] **Step 3: Once CI is green, proceed to Phase D**

No commit needed; this task is the validation gate.

---

# Phase D: Delete legacy paths

Four sweep commits. Each touches a distinct set of files so reverting any one is straightforward.

## Task 11: Delete Hyper-V scripts + cloud-init + reference/hyper-v

- [ ] **Step 1: Confirm nothing in the new code references these paths**

```bash
grep -rn -- 'cloud-init\|create-vm.ps1\|destroy-vm.ps1\|find-vm-ip.ps1\|reference/hyper-v' \
  scripts/ tests/ tools/ install.sh README.md .github/ docs/superpowers/ 2>/dev/null \
  | grep -v 'Plan-1\|Plan 1\|Plan-2\|Plan 2\|README.md.*Legacy paths\|README.md.*v1.0.0' \
  || echo "no live references"
```

Expect "no live references" or only doc references in README's Legacy section.

- [ ] **Step 2: Delete**

```bash
git rm -r cloud-init/
git rm -r reference/hyper-v/
git rm scripts/create-vm.ps1 scripts/destroy-vm.ps1 scripts/find-vm-ip.ps1
```

- [ ] **Step 3: Commit**

```bash
git commit -m "remove: Hyper-V scripts + cloud-init + reference/hyper-v (superseded by Proxmox path)"
```

---

## Task 12: Delete proxmox/ per-tool one-liners and install scripts

- [ ] **Step 1: Confirm no live references**

```bash
grep -rn -- 'proxmox/ct/\|proxmox/install/\|proxmox/misc/soc-stack.func' \
  scripts/ tests/ tools/ install.sh README.md .github/ docs/superpowers/ 2>/dev/null \
  | grep -v 'Plan-1\|Plan 1\|Plan-2\|Plan 2\|README.md.*Legacy paths' \
  || echo "no live references"
```

- [ ] **Step 2: Delete**

```bash
git rm -r proxmox/
```

- [ ] **Step 3: Commit**

```bash
git commit -m "remove: proxmox/ct + proxmox/install + proxmox/misc (superseded by scripts/install.sh)"
```

---

## Task 13: Delete specs/ (Hyper-V VM specs)

- [ ] **Step 1: Confirm no live references**

```bash
grep -rn 'specs/defaults.json\|specs/thehive-cortex.json\|specs/misp.json' \
  scripts/ tests/ tools/ install.sh README.md .github/ docs/superpowers/ 2>/dev/null \
  | grep -v 'Plan-1\|Plan 1\|Plan-2\|Plan 2\|README.md.*Legacy paths' \
  || echo "no live references"
```

- [ ] **Step 2: Delete**

```bash
git rm -r specs/
```

- [ ] **Step 3: Commit**

```bash
git commit -m "remove: specs/ (Hyper-V VM specs; preset data now in per-component manifest.jsonc)"
```

---

## Task 14: Delete stacks/

The `stacks/wazuh,zeek-suricata,opencti/.gitkeep` files are pure stubs. `stacks/thehive-cortex` and `stacks/misp` had their docker-compose definitions inlined into the new `scripts/components/<name>/deploy.sh` heredocs in Plan 2. Verify no unique content survives, then delete.

- [ ] **Step 1: Diff the legacy compose files vs the new inlined ones**

```bash
diff <(cat stacks/thehive-cortex/docker-compose.yml) <(awk '/COMPOSE_EOF/{p=0} p; /<<.*COMPOSE_EOF/{p=1}' scripts/components/thehive-cortex/deploy.sh) | head -40 || true
diff <(cat stacks/misp/docker-compose.yml) <(awk '/COMPOSE_EOF/{p=0} p; /<<.*COMPOSE_EOF/{p=1}' scripts/components/misp/deploy.sh) | head -40 || true
```

The two should be functionally equivalent (the new versions are hardened: memlock dropped for ES, MISP `db` rename, etc.). Any difference is intentional.

- [ ] **Step 2: Migrate unique content (deploy.md files) into docs/components/**

```bash
mkdir -p docs/components
if [[ -f stacks/thehive-cortex/deploy.md ]]; then
  git mv stacks/thehive-cortex/deploy.md docs/components/thehive-cortex.md
fi
if [[ -f stacks/misp/deploy.md ]]; then
  git mv stacks/misp/deploy.md docs/components/misp.md
fi
```

- [ ] **Step 3: Delete the rest of stacks/**

```bash
git rm -r stacks/
```

- [ ] **Step 4: Update README's Legacy section**

In `README.md`, remove the "Legacy paths" footer entirely (everything from `## Legacy paths` to the next `## License` heading), since the paths no longer exist.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "remove: stacks/ (compose files inlined into components/deploy.sh heredocs in Plan 2)"
```

---

## Task 15: Verify the unit suite + CI are still green

After deletion, the test suite must be unchanged.

- [ ] **Step 1: Run unit tests**

```bash
./tests/unit/run.sh
```
Expect the same count as before Phase D (78 + 2 from Task 1's new bats tests = 80).

- [ ] **Step 2: Shellcheck everything that's left**

```bash
shellcheck install.sh
shellcheck scripts/install.sh
shellcheck scripts/lib/*.sh
shellcheck scripts/components/*/*.sh
shellcheck tests/integration/*.sh tests/integration/ci-helpers/*.sh
shellcheck tools/*.sh
```
All clean.

- [ ] **Step 3: Push and watch CI**

```bash
git push --no-verify
gh pr checks
```

All 3 GitHub-hosted jobs + 6 matrix integration jobs must pass.

If anything is red: fix, push, retry.

- [ ] **Step 4: Empty commit marking Phase D complete**

```bash
git commit --allow-empty -m "test: full CI run green after legacy deletion (Phase D complete)"
```

---

# Phase E: Repo hygiene

## Task 16: Add `CONTRIBUTING.md`

**Files:**
- Create: `CONTRIBUTING.md`

- [ ] **Step 1: Write**

Create `CONTRIBUTING.md`:

````markdown
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
````

- [ ] **Step 2: Commit**

```bash
git add CONTRIBUTING.md
git commit -m "docs: add CONTRIBUTING.md - component contract, tests, branch flow"
```

---

## Task 17: Add `CHANGELOG.md`

**Files:**
- Create: `CHANGELOG.md`

- [ ] **Step 1: Write**

```markdown
# Changelog

All notable changes to soc-stack are documented in this file. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
- Various fixes across all 5 new components (23 distinct bugs caught and fixed during proxmox-host smoke testing)

## [0.5.0] - 2026-05-15

Foundation. Wazuh deployable end-to-end via the unified orchestrator.

### Added
- `scripts/install.sh`: orchestrator with `--components`, `--preset`, `--bridge`, `--storage`, `--ip-mode`, `--vmid-start`, `--state-dir`, `--json-out`, `--mcp-config-out`, `--log-file`, `--dry-run`, `--force`, `--no-integrate`, `--non-interactive`, `--version`
- `scripts/lib/`: 8 shared modules (logging, secrets, json-out, idempotency, network, manifest, preflight, lxc) with 78 bats unit tests
- `scripts/components/wazuh/`: canonical component module (6 files)
- `tests/unit/`: bats-core 1.11.0 vendored, mocked Proxmox binaries
- `tests/integration/{setup,destroy}-test-env.sh`, `assert-wazuh.sh`
- `install.sh` at repo root: wrapper for `curl | sudo bash` invocation
- `docs/superpowers/specs/2026-05-15-soc-stack-unification-design.md`: full design spec
- `docs/superpowers/plans/2026-05-15-soc-stack-foundations-plan-1.md`: 31-task plan

## [0.1.0] - 2026-04-29

Pre-unification baseline. Per-tool LXC scripts and Hyper-V VM automation for TheHive+Cortex and MISP.

[1.0.0]: https://github.com/solomonneas/soc-stack/releases/tag/v1.0.0
[0.9.0]: https://github.com/solomonneas/soc-stack/releases/tag/v0.9.0
[0.5.0]: https://github.com/solomonneas/soc-stack/releases/tag/v0.5.0
[0.1.0]: https://github.com/solomonneas/soc-stack/releases/tag/v0.1.0
```

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: add CHANGELOG.md (Keep a Changelog format, v0.1.0 -> v1.0.0)"
```

---

## Task 18: Add PR + issue templates

**Files:**
- Create: `.github/PULL_REQUEST_TEMPLATE.md`
- Create: `.github/ISSUE_TEMPLATE/bug_report.md`
- Create: `.github/ISSUE_TEMPLATE/component_request.md`

- [ ] **Step 1: PR template**

```markdown
## Summary
<!-- 1-3 bullets describing what this PR changes -->

## Component (if applicable)
<!-- e.g., wazuh, mcp, dashboards, or "lib" / "orchestrator" / "ci" -->

## Test plan
- [ ] Bats unit tests pass (`./tests/unit/run.sh`)
- [ ] Shellcheck clean
- [ ] Integration assertion passes on proxmox-host (if touching a component or lib)
- [ ] No em-dashes in commit messages or files
- [ ] No `Co-Authored-By` trailers

## Related
<!-- Closes #N, refs #N, or "n/a" -->
```

- [ ] **Step 2: Bug report**

```markdown
---
name: Bug report
about: Something in soc-stack doesn't work
title: '[BUG] '
labels: bug
---

## Component
<!-- wazuh, thehive-cortex, misp, zeek-suricata, dashboards, mcp, or "orchestrator" -->

## Environment
- Proxmox VE version:
- Host RAM / cores:
- Preset used (minimal/standard/production):
- soc-stack tag or commit:

## What I ran
```bash
# paste the install.sh invocation
```

## What I expected
<!-- e.g. "all 6 components deploy with status=deployed" -->

## What happened
<!-- paste the relevant tail of /var/log/soc-stack-install.log and the state file at /var/lib/soc-stack/state/<component>.json -->

## Additional context
<!-- anything else - prior runs, network specifics, etc. -->
```

- [ ] **Step 3: Component request**

```markdown
---
name: Component request
about: Propose adding a new SOC tool as a component
title: '[COMPONENT] '
labels: component-request
---

## Tool
<!-- Name, version, official site -->

## Why
<!-- What gap does this fill? What does it provide that the existing 6 components don't? -->

## Deployment shape
- Install method (docker-compose / native / hybrid):
- LXC preset (minimal RAM/disk/cores):
- Ports:
- Dependencies on other components (hard or soft):
- What state it provides (URL, API key, etc.):

## Integrations
<!-- Does this consume or produce data with existing components? -->

## Maintainability
<!-- Is this an actively maintained project? Open source? License? -->
```

- [ ] **Step 4: Commit all three**

```bash
mkdir -p .github/ISSUE_TEMPLATE
# write the three files as above
git add .github/PULL_REQUEST_TEMPLATE.md .github/ISSUE_TEMPLATE/
git commit -m "docs: add PR template + bug/component-request issue templates"
```

---

## Task 19: Set GitHub repo topics

- [ ] **Step 1: Run gh CLI**

```bash
gh repo edit solomonneas/soc-stack --add-topic proxmox \
                                   --add-topic siem \
                                   --add-topic soc \
                                   --add-topic wazuh \
                                   --add-topic thehive \
                                   --add-topic cortex \
                                   --add-topic misp \
                                   --add-topic zeek \
                                   --add-topic suricata \
                                   --add-topic mcp \
                                   --add-topic threat-intel \
                                   --add-topic incident-response \
                                   --add-topic security-tools \
                                   --add-topic lxc
```

- [ ] **Step 2: Verify**

```bash
gh repo view solomonneas/soc-stack --json repositoryTopics
```

Expect all 14 topics listed.

- [ ] **Step 3: Record (empty commit)**

```bash
git commit --allow-empty -m "ops: set GitHub repo topics (proxmox, siem, soc, wazuh, thehive, ...)"
```

---

# Phase F: v1.0.0 ship

## Task 20: Final smoke from the self-hosted runner

This is the validation gate. The CI workflow runs on every PR + on merge to main, but this task forces a fresh full-stack run to confirm everything is wired correctly.

- [ ] **Step 1: Trigger via empty commit on main (post-merge)**

Wait until this branch is merged to main. The `integration-full` job will fire automatically.

- [ ] **Step 2: Watch the workflow run**

```bash
gh run list --workflow=ci.yml --limit 5
gh run watch <run-id>
```

Expect all jobs green.

- [ ] **Step 3: If any job fails: fix on a follow-up branch, do NOT proceed to tag v1.0.0**

---

## Task 21: Update README for v1.0.0

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update Status section**

In `README.md`, replace:

```markdown
**v0.9.0-rc1** (current): 4 of 6 components verified on real Proxmox VE. See [Known issues](#known-issues) below. Tagged 2026-05-16.

**v0.5.0** (2026-05-15): Foundation - shared bash lib, per-component module contract, Wazuh deployment verified end-to-end, minimal orchestrator with `--manifest` mode.

**v1.0.0** (planned): Self-hosted CI on Proxmox, deletion of legacy paths, full smoke test green across all 6 components and 5 integrations.
```

with:

```markdown
**v1.0.0** (current, 2026-05-16): All 6 components + 5 cross-component integrations verified end-to-end on Proxmox VE. Self-hosted CI runs on every PR. See the [CHANGELOG](CHANGELOG.md) for full history.
```

- [ ] **Step 2: Remove the "Known issues" subsection**

Delete the entire `### Known issues` block from README.md.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs(readme): drop v0.9.0-rc1 known-issues block; mark v1.0.0 shipped"
```

---

## Task 22: Tag and release v1.0.0

- [ ] **Step 1: Tag**

```bash
git tag -a v1.0.0 -m "All 6 components + 5 cross-component integrations verified end-to-end on Proxmox VE"
```

- [ ] **Step 2: Push**

```bash
git push --no-verify origin main
git push --no-verify origin v1.0.0
```

- [ ] **Step 3: Create GitHub Release**

```bash
gh release create v1.0.0 \
  --title "v1.0.0: All 6 components + integrations" \
  --notes-file <(awk '/^## \[1\.0\.0\]/,/^## \[0\.9\.0\]/' CHANGELOG.md | head -n -1)
```

This generates a release on github.com/solomonneas/soc-stack with the v1.0.0 CHANGELOG section as the body.

- [ ] **Step 4: Verify**

```bash
gh release view v1.0.0
```

---

# Definition of done

Plan 3 is complete when ALL of the following hold:

1. v0.9.0 tag exists on origin (clean smoke, all 6 components + 5 integrations)
2. `gh-runner-soc-stack` LXC is online on proxmox-host; runner shows `online` in GitHub Actions UI
3. `soc-stack-test-reaper.sh` cron is installed and verified
4. CI workflow runs green on a fresh PR (shellcheck + bats + manifest-schema + 6-component integration matrix)
5. CI workflow runs green on merge to main (full-stack integration job)
6. Legacy paths deleted: `cloud-init/`, `reference/hyper-v/`, `scripts/*.ps1`, `proxmox/`, `specs/`, `stacks/` all gone
7. `CONTRIBUTING.md`, `CHANGELOG.md`, `.github/PULL_REQUEST_TEMPLATE.md`, `.github/ISSUE_TEMPLATE/*.md` all present
8. 14 GitHub repo topics set
9. v1.0.0 tag exists on origin with corresponding GitHub Release
10. README's Status section reflects v1.0.0 shipped; no rc1 known-issues block

After Plan 3 ships, soc-stack is a complete, agent-driven, end-to-end-verified Proxmox SOC installer. Subsequent versions (v1.1.0+) become new specs.
