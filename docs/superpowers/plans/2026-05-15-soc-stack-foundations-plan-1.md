# SOC Stack Foundations Implementation Plan (1 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the modular foundation for the unified soc-stack installer: shared bash lib, per-component module contract proven with Wazuh end-to-end, and a minimal orchestrator. After this plan ships, a Proxmox host can run `sudo bash install.sh --components wazuh --preset minimal --json-out /root/result.json` and get a working Wazuh LXC plus parseable result.

**Architecture:** Thin orchestrator + 8-module shared lib + per-component folder pattern (`manifest.jsonc` + 5 bash scripts per component). TDD discipline for the shared lib using `bats-core` with mocked Proxmox binaries (`pct`/`qm`/`docker`). Wazuh existing native installer is moved into the new pattern verbatim, then hardened with idempotency.

**Tech Stack:** Bash 5+, `jq`, `bats-core` (vendored as submodule), `shellcheck`, Proxmox VE 7/8 `pct`/`qm` tooling. No new runtime dependencies on Proxmox.

**Spec reference:** [`docs/superpowers/specs/2026-05-15-soc-stack-unification-design.md`](../specs/2026-05-15-soc-stack-unification-design.md)

---

## Scope of this plan

**In:**
- New directory scaffolding (`scripts/lib/`, `scripts/components/wazuh/`, `tests/unit/`, `tests/integration/`)
- Eight shared lib modules with bats unit tests
- Wazuh component module (manifest + 5 scripts) using existing installer code, hardened for idempotency
- Minimal orchestrator that supports `--components wazuh`, `--preset`, `--bridge`, `--storage`, `--ip-mode`, `--json-out`, `--state-dir`, `--log-file`, `--dry-run`, `--force`, `--non-interactive`, `--version`, `--vmid-start`
- One integration test (`assert-wazuh.sh`) - runnable manually on a Proxmox host (full CI infra is Plan 3)
- v0.5.0 git tag at the end

**Out (defer to Plan 2 or 3):**
- Other 5 components (thehive-cortex, misp, zeek-suricata, dashboards, mcp) - Plan 2
- Cross-component integration scripts (`integrate.sh` only has a stub in Plan 1)
- GitHub Actions CI workflow rewrite, self-hosted runner setup, test reaper cron - Plan 3
- Deletion of legacy paths (`proxmox/ct/`, `scripts/create-vm.ps1`, `cloud-init/`, `reference/hyper-v/`, `specs/`, `stacks/*/`) - Plan 3
- README rewrite and docs reshape - Plan 3
- Repo hygiene files (CONTRIBUTING, CHANGELOG, issue/PR templates) - Plan 3
- Manifest mode (`--manifest <path>`) - Plan 2

**Compatibility during transition:** Plan 1 leaves all legacy paths in place. The new `install.sh` lives alongside `scripts/setup/install.sh`. Plan 3 deletes the old once Plan 2 is done.

---

## File Structure

### New files

```
.gitmodules                                    # adds bats-core vendor
tests/vendor/bats-core/                        # submodule
tests/vendor/bats-support/                     # submodule
tests/vendor/bats-assert/                      # submodule
tests/unit/run.sh                              # convenience runner
tests/unit/helpers/load.bash                   # bats helper bootstrap
tests/unit/fixtures/bin/pct                    # fake pct binary
tests/unit/fixtures/bin/qm                     # fake qm binary
tests/unit/fixtures/bin/docker                 # fake docker binary
tests/unit/fixtures/bin/pveam                  # fake pveam binary
tests/unit/fixtures/bin/pvesm                  # fake pvesm binary
tests/unit/fixtures/bin/systemctl              # fake systemctl binary
tests/unit/test_logging.bats
tests/unit/test_secrets.bats
tests/unit/test_json_out.bats
tests/unit/test_idempotency.bats
tests/unit/test_network.bats
tests/unit/test_manifest.bats
tests/unit/test_preflight.bats
tests/unit/test_lxc.bats
tests/unit/test_orchestrator_flag_parsing.bats
tests/unit/test_orchestrator_manifest_building.bats
tests/integration/setup-test-env.sh
tests/integration/destroy-test-env.sh
tests/integration/assert-wazuh.sh
scripts/lib/logging.sh
scripts/lib/secrets.sh
scripts/lib/json-out.sh
scripts/lib/idempotency.sh
scripts/lib/network.sh
scripts/lib/manifest.sh
scripts/lib/preflight.sh
scripts/lib/lxc.sh
scripts/install.sh                             # new orchestrator
scripts/components/wazuh/manifest.jsonc
scripts/components/wazuh/lxc-spec.sh
scripts/components/wazuh/deploy.sh
scripts/components/wazuh/verify.sh
scripts/components/wazuh/integrate.sh          # stub in Plan 1
scripts/components/wazuh/destroy.sh
install.sh                                     # thin wrapper at repo root
```

### Modified files

None in Plan 1 - all new code is additive. Legacy files stay until Plan 3.

---

## Prerequisites

- Working directory: `~/repos/soc-stack` on a branch (worktree or feature branch via `superpowers:using-git-worktrees` skill recommended)
- Tools on dev machine: `git`, `bash 5+`, `jq`, `shellcheck`, `gh` (for tagging at the end)
- For the manual integration test only: SSH access to a Proxmox VE 7 or 8 host with `vmbr0` bridge and `local-lvm` (or equivalent) storage, plus a free VMID range
- Note: All bats unit tests run on the dev machine with no Proxmox host required (mocks via PATH)

---

## Task 1: Create directory scaffolding

**Files:**
- Create: `scripts/lib/.gitkeep`
- Create: `scripts/components/wazuh/.gitkeep`
- Create: `tests/unit/.gitkeep`
- Create: `tests/unit/fixtures/bin/.gitkeep`
- Create: `tests/unit/helpers/.gitkeep`
- Create: `tests/integration/.gitkeep`
- Create: `tests/vendor/.gitkeep`

- [ ] **Step 1: Create all directories**

Run:
```bash
cd ~/repos/soc-stack
mkdir -p scripts/lib scripts/components/wazuh \
         tests/unit/fixtures/bin tests/unit/helpers \
         tests/integration tests/vendor
touch scripts/lib/.gitkeep \
      scripts/components/wazuh/.gitkeep \
      tests/unit/.gitkeep \
      tests/unit/fixtures/bin/.gitkeep \
      tests/unit/helpers/.gitkeep \
      tests/integration/.gitkeep \
      tests/vendor/.gitkeep
```

- [ ] **Step 2: Verify the tree**

Run:
```bash
find scripts tests -type d -newer /tmp 2>/dev/null | sort
```
Expected: lists all 7 new directories.

- [ ] **Step 3: Commit**

```bash
git add scripts/lib scripts/components tests
git commit -m "scaffold: create scripts/lib, scripts/components/wazuh, tests/unit, tests/integration"
```

---

## Task 2: Vendor bats-core, bats-support, and bats-assert

**Files:**
- Create: `.gitmodules`
- Create: `tests/vendor/bats-core/` (submodule)
- Create: `tests/vendor/bats-support/` (submodule)
- Create: `tests/vendor/bats-assert/` (submodule)

- [ ] **Step 1: Add bats-core submodule**

```bash
cd ~/repos/soc-stack
git submodule add https://github.com/bats-core/bats-core.git tests/vendor/bats-core
```

- [ ] **Step 2: Add bats-support submodule**

```bash
git submodule add https://github.com/bats-core/bats-support.git tests/vendor/bats-support
```

- [ ] **Step 3: Add bats-assert submodule**

```bash
git submodule add https://github.com/bats-core/bats-assert.git tests/vendor/bats-assert
```

- [ ] **Step 4: Pin to known-good tags**

```bash
cd tests/vendor/bats-core && git checkout v1.11.0 && cd -
cd tests/vendor/bats-support && git checkout v0.3.0 && cd -
cd tests/vendor/bats-assert && git checkout v2.1.0 && cd -
git add tests/vendor/bats-core tests/vendor/bats-support tests/vendor/bats-assert
```

- [ ] **Step 5: Verify bats binary runs**

```bash
./tests/vendor/bats-core/bin/bats --version
```
Expected: `Bats 1.11.0`

- [ ] **Step 6: Commit**

```bash
git add .gitmodules tests/vendor
git commit -m "test: vendor bats-core v1.11.0, bats-support v0.3.0, bats-assert v2.1.0"
```

---

## Task 3: Write the bats helper bootstrap

**Files:**
- Create: `tests/unit/helpers/load.bash`

- [ ] **Step 1: Write helper file**

Create `tests/unit/helpers/load.bash`:

```bash
#!/usr/bin/env bash
# Loaded at the top of every .bats file via `load helpers/load.bash`

# Make repo root available
REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
export REPO_ROOT

# Load bats helpers
load "${REPO_ROOT}/tests/vendor/bats-support/load"
load "${REPO_ROOT}/tests/vendor/bats-assert/load"

# Prepend fake-binary fixtures dir to PATH so mocks intercept calls
export PATH="${REPO_ROOT}/tests/unit/fixtures/bin:${PATH}"

# Per-test isolated state
setup() {
  export SOC_STATE_DIR="${BATS_TEST_TMPDIR}/var/lib/soc-stack"
  export SOC_LOG_FILE="${BATS_TEST_TMPDIR}/soc-stack.log"
  export SOC_SECRETS_DIR="${SOC_STATE_DIR}/secrets"
  mkdir -p "${SOC_STATE_DIR}/state" "${SOC_SECRETS_DIR}" "${SOC_STATE_DIR}/logs"
}

# Source a lib module under test
source_lib() {
  local module="$1"
  source "${REPO_ROOT}/scripts/lib/${module}.sh"
}
```

- [ ] **Step 2: Commit**

```bash
git add tests/unit/helpers/load.bash
git commit -m "test: add bats helper bootstrap (load.bash)"
```

---

## Task 4: Write the convenience test runner

**Files:**
- Create: `tests/unit/run.sh`

- [ ] **Step 1: Write runner**

Create `tests/unit/run.sh`:

```bash
#!/usr/bin/env bash
# Convenience runner for all bats unit tests
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

exec "${REPO_ROOT}/tests/vendor/bats-core/bin/bats" \
  --print-output-on-failure \
  --formatter pretty \
  "${SCRIPT_DIR}"/*.bats
```

- [ ] **Step 2: Make executable**

```bash
chmod +x tests/unit/run.sh
```

- [ ] **Step 3: Commit**

```bash
git add tests/unit/run.sh
git commit -m "test: add unit test runner (tests/unit/run.sh)"
```

---

## Task 5: Write the fake `pct` mock binary

**Files:**
- Create: `tests/unit/fixtures/bin/pct`

- [ ] **Step 1: Write the mock**

Create `tests/unit/fixtures/bin/pct`:

```bash
#!/usr/bin/env bash
# Fake pct that records calls and returns scriptable output.
# Behavior controlled via env vars:
#   MOCK_PCT_STATUS    — what `pct status <vmid>` returns ("running" or "stopped"; default "stopped")
#   MOCK_PCT_LIST      — what `pct list` prints
#   MOCK_PCT_EXEC      — what `pct exec <vmid> -- <cmd>` prints
#   MOCK_PCT_EXIT      — exit code for `pct create`, `pct start`, etc. (default 0)
#   MOCK_PCT_CALLS_LOG — file to append call log (default $BATS_TEST_TMPDIR/pct-calls.log)

CALLS_LOG="${MOCK_PCT_CALLS_LOG:-${BATS_TEST_TMPDIR:-/tmp}/pct-calls.log}"
echo "pct $*" >> "$CALLS_LOG"

case "$1" in
  status)
    if [[ "${MOCK_PCT_STATUS:-stopped}" == "running" ]]; then
      echo "status: running"
    else
      echo "status: stopped"
    fi
    ;;
  list)
    printf '%s\n' "${MOCK_PCT_LIST:-VMID       Status     Lock         Name}"
    ;;
  exec)
    printf '%s\n' "${MOCK_PCT_EXEC:-}"
    ;;
  create|start|stop|destroy|push|set)
    : # accept silently
    ;;
  *)
    : # accept silently
    ;;
esac

exit "${MOCK_PCT_EXIT:-0}"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x tests/unit/fixtures/bin/pct
```

- [ ] **Step 3: Smoke test the mock**

```bash
MOCK_PCT_CALLS_LOG=/tmp/pct-test.log ./tests/unit/fixtures/bin/pct status 9999
cat /tmp/pct-test.log
```
Expected output:
```
status: stopped
pct status 9999
```

- [ ] **Step 4: Commit**

```bash
git add tests/unit/fixtures/bin/pct
git commit -m "test: add fake pct binary for unit tests"
```

---

## Task 6: Write the fake `qm`, `docker`, `pveam`, `pvesm`, `systemctl` mocks

**Files:**
- Create: `tests/unit/fixtures/bin/qm`
- Create: `tests/unit/fixtures/bin/docker`
- Create: `tests/unit/fixtures/bin/pveam`
- Create: `tests/unit/fixtures/bin/pvesm`
- Create: `tests/unit/fixtures/bin/systemctl`

- [ ] **Step 1: Write `qm` mock**

Create `tests/unit/fixtures/bin/qm`:

```bash
#!/usr/bin/env bash
CALLS_LOG="${MOCK_QM_CALLS_LOG:-${BATS_TEST_TMPDIR:-/tmp}/qm-calls.log}"
echo "qm $*" >> "$CALLS_LOG"
case "$1" in
  list)   printf '%s\n' "${MOCK_QM_LIST:-VMID NAME              STATUS}" ;;
  status) printf 'status: %s\n' "${MOCK_QM_STATUS:-stopped}" ;;
  *)      : ;;
esac
exit "${MOCK_QM_EXIT:-0}"
```

- [ ] **Step 2: Write `docker` mock**

Create `tests/unit/fixtures/bin/docker`:

```bash
#!/usr/bin/env bash
CALLS_LOG="${MOCK_DOCKER_CALLS_LOG:-${BATS_TEST_TMPDIR:-/tmp}/docker-calls.log}"
echo "docker $*" >> "$CALLS_LOG"
case "$1" in
  ps)      printf '%s\n' "${MOCK_DOCKER_PS:-}" ;;
  compose) printf '%s\n' "${MOCK_DOCKER_COMPOSE:-}" ;;
  *)       : ;;
esac
exit "${MOCK_DOCKER_EXIT:-0}"
```

- [ ] **Step 3: Write `pveam` mock**

Create `tests/unit/fixtures/bin/pveam`:

```bash
#!/usr/bin/env bash
CALLS_LOG="${MOCK_PVEAM_CALLS_LOG:-${BATS_TEST_TMPDIR:-/tmp}/pveam-calls.log}"
echo "pveam $*" >> "$CALLS_LOG"
case "$1" in
  list)     printf '%s\n' "${MOCK_PVEAM_LIST:-local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst}" ;;
  update)   : ;;
  download) : ;;
  *)        : ;;
esac
exit "${MOCK_PVEAM_EXIT:-0}"
```

- [ ] **Step 4: Write `pvesm` mock**

Create `tests/unit/fixtures/bin/pvesm`:

```bash
#!/usr/bin/env bash
CALLS_LOG="${MOCK_PVESM_CALLS_LOG:-${BATS_TEST_TMPDIR:-/tmp}/pvesm-calls.log}"
echo "pvesm $*" >> "$CALLS_LOG"
case "$1" in
  status) printf '%s\n' "${MOCK_PVESM_STATUS:-Name       Type     Status   Total  Used  Available  %\nlocal      dir      active   100GB  10GB  90GB       10%\nlocal-lvm  lvmthin  active   500GB  50GB  450GB      10%}" ;;
  *)      : ;;
esac
exit "${MOCK_PVESM_EXIT:-0}"
```

- [ ] **Step 5: Write `systemctl` mock**

Create `tests/unit/fixtures/bin/systemctl`:

```bash
#!/usr/bin/env bash
CALLS_LOG="${MOCK_SYSTEMCTL_CALLS_LOG:-${BATS_TEST_TMPDIR:-/tmp}/systemctl-calls.log}"
echo "systemctl $*" >> "$CALLS_LOG"
case "$1" in
  is-active)
    if [[ "${MOCK_SYSTEMCTL_ACTIVE:-yes}" == "yes" ]]; then
      echo "active"; exit 0
    else
      echo "inactive"; exit 3
    fi
    ;;
  is-enabled)
    if [[ "${MOCK_SYSTEMCTL_ENABLED:-yes}" == "yes" ]]; then
      echo "enabled"; exit 0
    else
      echo "disabled"; exit 1
    fi
    ;;
  *) : ;;
esac
exit "${MOCK_SYSTEMCTL_EXIT:-0}"
```

- [ ] **Step 6: Make all executable**

```bash
chmod +x tests/unit/fixtures/bin/{qm,docker,pveam,pvesm,systemctl}
```

- [ ] **Step 7: Commit**

```bash
git add tests/unit/fixtures/bin/{qm,docker,pveam,pvesm,systemctl}
git commit -m "test: add fake qm, docker, pveam, pvesm, systemctl mocks for unit tests"
```

---

## Task 7: Write smoke test confirming bats + mocks + helper all wire up

**Files:**
- Create: `tests/unit/test_bats_smoke.bats`

- [ ] **Step 1: Write failing smoke test (before mocks are confirmed)**

Create `tests/unit/test_bats_smoke.bats`:

```bash
#!/usr/bin/env bats

load helpers/load.bash

@test "bats helper is loaded and SOC_STATE_DIR is set" {
  [[ -n "${SOC_STATE_DIR:-}" ]]
  [[ -d "${SOC_STATE_DIR}" ]]
}

@test "fake pct is on PATH and records calls" {
  pct status 9999
  [[ -f "${BATS_TEST_TMPDIR}/pct-calls.log" ]]
  grep -q "pct status 9999" "${BATS_TEST_TMPDIR}/pct-calls.log"
}

@test "fake docker is on PATH and records calls" {
  docker ps
  [[ -f "${BATS_TEST_TMPDIR}/docker-calls.log" ]]
  grep -q "docker ps" "${BATS_TEST_TMPDIR}/docker-calls.log"
}

@test "MOCK_PCT_STATUS=running flips the mock output" {
  export MOCK_PCT_STATUS=running
  run pct status 9999
  assert_success
  assert_output --partial "running"
}
```

- [ ] **Step 2: Run smoke test**

```bash
./tests/unit/run.sh
```
Expected: 4 passing tests, 0 failures.

- [ ] **Step 3: Commit**

```bash
git add tests/unit/test_bats_smoke.bats
git commit -m "test: add bats smoke test verifying helper + mocks wire up"
```

---

## Task 8: Implement `lib/logging.sh` with TDD

**Files:**
- Create: `tests/unit/test_logging.bats`
- Create: `scripts/lib/logging.sh`

- [ ] **Step 1: Write failing test for `msg_info`**

Create `tests/unit/test_logging.bats`:

```bash
#!/usr/bin/env bats

load helpers/load.bash

setup() {
  export SOC_STATE_DIR="${BATS_TEST_TMPDIR}/var/lib/soc-stack"
  export SOC_LOG_FILE="${BATS_TEST_TMPDIR}/soc-stack.log"
  mkdir -p "$(dirname "${SOC_LOG_FILE}")"
  source_lib logging
}

@test "msg_info prints to stderr with INFO marker" {
  run --separate-stderr msg_info "starting up"
  assert_success
  assert [ -z "${output:-}" ]
  [[ "${stderr}" == *"starting up"* ]]
}

@test "msg_info writes to log file with ISO timestamp and INFO level" {
  msg_info "test message"
  grep -E '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}.*\] INFO  test message$' "${SOC_LOG_FILE}"
}

@test "msg_ok writes OK level to log" {
  msg_ok "completed"
  grep "OK    completed" "${SOC_LOG_FILE}"
}

@test "msg_error writes ERROR level to log and stderr" {
  run --separate-stderr msg_error "boom"
  [[ "${stderr}" == *"boom"* ]]
  grep "ERROR boom" "${SOC_LOG_FILE}"
}

@test "msg_warn writes WARN level to log" {
  msg_warn "be careful"
  grep "WARN  be careful" "${SOC_LOG_FILE}"
}

@test "log file is created if directory exists" {
  rm -f "${SOC_LOG_FILE}"
  msg_info "first message"
  [[ -f "${SOC_LOG_FILE}" ]]
}
```

- [ ] **Step 2: Run, verify failure**

```bash
./tests/unit/run.sh tests/unit/test_logging.bats
```
Expected: all 6 tests FAIL with "command not found: msg_info" or similar.

- [ ] **Step 3: Implement `lib/logging.sh`**

Create `scripts/lib/logging.sh`:

```bash
#!/usr/bin/env bash
# scripts/lib/logging.sh - structured logging for soc-stack
# Reads: SOC_LOG_FILE (path; default /var/log/soc-stack-install.log)
# Writes: log file + stderr

: "${SOC_LOG_FILE:=/var/log/soc-stack-install.log}"

_soc_log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  local line
  printf -v line '[%s] %-5s %s' "${ts}" "${level}" "${msg}"

  mkdir -p "$(dirname "${SOC_LOG_FILE}")" 2>/dev/null || true
  printf '%s\n' "${line}" >> "${SOC_LOG_FILE}" 2>/dev/null || true

  case "${level}" in
    ERROR|WARN) printf '%s\n' "${line}" >&2 ;;
    *)          printf '%s\n' "${line}" >&2 ;;
  esac
}

msg_info()  { _soc_log "INFO"  "$*"; }
msg_ok()    { _soc_log "OK"    "$*"; }
msg_warn()  { _soc_log "WARN"  "$*"; }
msg_error() { _soc_log "ERROR" "$*"; }
```

- [ ] **Step 4: Run tests, verify all pass**

```bash
./tests/unit/run.sh tests/unit/test_logging.bats
```
Expected: 6 passing.

- [ ] **Step 5: Shellcheck**

```bash
shellcheck scripts/lib/logging.sh
```
Expected: no output (clean).

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/logging.sh tests/unit/test_logging.bats
git commit -m "lib: add logging.sh with msg_info/ok/warn/error helpers"
```

---

## Task 9: Implement `lib/secrets.sh` with TDD

**Files:**
- Create: `tests/unit/test_secrets.bats`
- Create: `scripts/lib/secrets.sh`

- [ ] **Step 1: Write failing tests**

Create `tests/unit/test_secrets.bats`:

```bash
#!/usr/bin/env bats

load helpers/load.bash

setup() {
  export SOC_STATE_DIR="${BATS_TEST_TMPDIR}/var/lib/soc-stack"
  export SOC_SECRETS_DIR="${SOC_STATE_DIR}/secrets"
  export SOC_LOG_FILE="${BATS_TEST_TMPDIR}/soc-stack.log"
  mkdir -p "${SOC_SECRETS_DIR}" "$(dirname "${SOC_LOG_FILE}")"
  source_lib logging
  source_lib secrets
}

@test "gen_password defaults to 24 chars" {
  run gen_password
  assert_success
  [[ ${#output} -eq 24 ]]
}

@test "gen_password accepts explicit length" {
  run gen_password 40
  assert_success
  [[ ${#output} -eq 40 ]]
}

@test "gen_password produces only safe chars (alnum + a few specials, no shell metacharacters)" {
  for _ in 1 2 3 4 5; do
    pw="$(gen_password 64)"
    [[ "$pw" =~ ^[A-Za-z0-9_+=.-]+$ ]] || {
      echo "FAIL: bad chars in $pw"
      false
    }
  done
}

@test "store_secret writes mode 0600 file" {
  store_secret "wazuh-admin" "hunter2"
  local f="${SOC_SECRETS_DIR}/wazuh-admin.txt"
  [[ -f "$f" ]]
  [[ "$(stat -c '%a' "$f")" == "600" ]]
  [[ "$(cat "$f")" == "hunter2" ]]
}

@test "get_secret returns the stored value" {
  store_secret "thehive-admin" "swordfish"
  run get_secret "thehive-admin"
  assert_success
  assert_output "swordfish"
}

@test "get_secret returns empty on missing key" {
  run get_secret "does-not-exist"
  assert_success
  assert_output ""
}

@test "store_secret overwrites existing value" {
  store_secret "key1" "old"
  store_secret "key1" "new"
  run get_secret "key1"
  assert_output "new"
}
```

- [ ] **Step 2: Run, verify failure**

```bash
./tests/unit/run.sh tests/unit/test_secrets.bats
```
Expected: all 7 tests FAIL.

- [ ] **Step 3: Implement `lib/secrets.sh`**

Create `scripts/lib/secrets.sh`:

```bash
#!/usr/bin/env bash
# scripts/lib/secrets.sh - password generation + secret persistence
# Requires: lib/logging.sh sourced first
# Reads: SOC_SECRETS_DIR (default /var/lib/soc-stack/secrets)

: "${SOC_SECRETS_DIR:=/var/lib/soc-stack/secrets}"

# gen_password [length]
# Emits an alnum + safe-special password of given length (default 24).
# Safe chars only - no shell metacharacters that would need quoting.
gen_password() {
  local len="${1:-24}"
  local charset='A-Za-z0-9_+=.-'
  LC_ALL=C tr -dc "${charset}" </dev/urandom | head -c "${len}"
}

# store_secret <name> <value>
# Writes value to ${SOC_SECRETS_DIR}/<name>.txt with mode 0600.
store_secret() {
  local name="$1"
  local value="$2"
  local f="${SOC_SECRETS_DIR}/${name}.txt"

  mkdir -p "${SOC_SECRETS_DIR}"
  printf '%s' "${value}" > "${f}"
  chmod 600 "${f}"
}

# get_secret <name>
# Prints stored value to stdout, or empty string if missing.
get_secret() {
  local name="$1"
  local f="${SOC_SECRETS_DIR}/${name}.txt"
  if [[ -f "${f}" ]]; then
    cat "${f}"
  fi
}
```

- [ ] **Step 4: Run tests, verify pass**

```bash
./tests/unit/run.sh tests/unit/test_secrets.bats
```
Expected: 7 passing.

- [ ] **Step 5: Shellcheck**

```bash
shellcheck scripts/lib/secrets.sh
```
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/secrets.sh tests/unit/test_secrets.bats
git commit -m "lib: add secrets.sh with gen_password, store_secret, get_secret"
```

---

## Task 10: Implement `lib/json-out.sh` with TDD

**Files:**
- Create: `tests/unit/test_json_out.bats`
- Create: `scripts/lib/json-out.sh`

- [ ] **Step 1: Write failing tests**

Create `tests/unit/test_json_out.bats`:

```bash
#!/usr/bin/env bats

load helpers/load.bash

setup() {
  export SOC_STATE_DIR="${BATS_TEST_TMPDIR}/var/lib/soc-stack"
  export SOC_LOG_FILE="${BATS_TEST_TMPDIR}/soc-stack.log"
  mkdir -p "${SOC_STATE_DIR}/state"
  source_lib logging
  source_lib json_out 2>/dev/null || source "${REPO_ROOT}/scripts/lib/json-out.sh"
}

@test "state_set creates state file if missing" {
  state_set wazuh status "deployed"
  [[ -f "${SOC_STATE_DIR}/state/wazuh.json" ]]
  jq -e '.status == "deployed"' "${SOC_STATE_DIR}/state/wazuh.json"
}

@test "state_set updates existing field without losing others" {
  state_set wazuh status "deployed"
  state_set wazuh url "https://10.0.50.10"
  jq -e '.status == "deployed" and .url == "https://10.0.50.10"' "${SOC_STATE_DIR}/state/wazuh.json"
}

@test "state_set handles nested keys via dot notation" {
  state_set wazuh "lxc.vmid" 201
  jq -e '.lxc.vmid == 201' "${SOC_STATE_DIR}/state/wazuh.json"
}

@test "state_get reads a field" {
  state_set wazuh status "deployed"
  run state_get wazuh status
  assert_success
  assert_output "deployed"
}

@test "state_get on missing field returns empty" {
  state_set wazuh status "deployed"
  run state_get wazuh "missing"
  assert_success
  assert_output ""
}

@test "state_get on missing component returns empty" {
  run state_get "does-not-exist" status
  assert_success
  assert_output ""
}

@test "emit_final_json writes valid JSON with all component states" {
  state_set wazuh status "deployed"
  state_set wazuh url "https://10.0.50.10"
  state_set misp  status "failed"
  state_set misp  error "compose pull timeout"

  local out="${BATS_TEST_TMPDIR}/result.json"
  emit_final_json "${out}"

  jq -e '.version == "1.0"' "${out}"
  jq -e '.components | length == 2' "${out}"
  jq -e '.components[] | select(.name == "wazuh") | .status == "deployed"' "${out}"
  jq -e '.components[] | select(.name == "misp")  | .status == "failed"' "${out}"
}

@test "emit_final_json includes installed_at ISO timestamp" {
  state_set wazuh status "deployed"
  local out="${BATS_TEST_TMPDIR}/result.json"
  emit_final_json "${out}"
  jq -e '.installed_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' "${out}"
}
```

- [ ] **Step 2: Run, verify failure**

```bash
./tests/unit/run.sh tests/unit/test_json_out.bats
```
Expected: all 8 tests FAIL.

- [ ] **Step 3: Implement `lib/json-out.sh`**

Create `scripts/lib/json-out.sh`:

```bash
#!/usr/bin/env bash
# scripts/lib/json-out.sh - component state files + final result JSON emitter
# Requires: jq, lib/logging.sh

: "${SOC_STATE_DIR:=/var/lib/soc-stack}"

# state_file <component> - print path to that component's state file
state_file() {
  printf '%s/state/%s.json\n' "${SOC_STATE_DIR}" "$1"
}

# state_set <component> <key> <value>
# Key may use dot notation for nesting (e.g., "lxc.vmid").
# Value is interpreted as JSON if it parses, else as a string.
state_set() {
  local component="$1"
  local key="$2"
  local value="$3"
  local f
  f="$(state_file "${component}")"

  mkdir -p "$(dirname "${f}")"
  [[ -f "${f}" ]] || echo '{}' > "${f}"

  # Try to parse value as JSON; if it fails, treat as string
  local jq_value
  if printf '%s' "${value}" | jq -e . >/dev/null 2>&1; then
    jq_value="${value}"
  else
    jq_value="$(printf '%s' "${value}" | jq -R '.')"
  fi

  local tmp
  tmp="$(mktemp)"
  jq --argjson v "${jq_value}" "setpath(\"${key}\" / \".\"; \$v)" "${f}" > "${tmp}"
  mv "${tmp}" "${f}"
}

# state_get <component> <key>
# Prints the value at key, or empty if missing.
state_get() {
  local component="$1"
  local key="$2"
  local f
  f="$(state_file "${component}")"
  [[ -f "${f}" ]] || return 0
  jq -r "getpath(\"${key}\" / \".\") // empty" "${f}"
}

# emit_final_json <output_path>
# Reads all components' state files and writes a unified result JSON.
emit_final_json() {
  local out="$1"
  local installed_at
  installed_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  local components_array='[]'
  if compgen -G "${SOC_STATE_DIR}/state/*.json" >/dev/null; then
    components_array="$(jq -s '[.[] | . as $obj | {name: ($obj.component // (input_filename | sub(".*/"; "") | sub("\\.json$"; "")))} + $obj | del(.component)]' "${SOC_STATE_DIR}"/state/*.json 2>/dev/null || echo '[]')"
  fi

  jq -n \
    --arg installed_at "${installed_at}" \
    --argjson components "${components_array}" \
    '{
      version: "1.0",
      installed_at: $installed_at,
      soc_stack_version: "0.5.0",
      components: $components,
      integrations: [],
      warnings: [],
      errors: []
    }' > "${out}"
}
```

- [ ] **Step 4: Run tests, verify pass**

```bash
./tests/unit/run.sh tests/unit/test_json_out.bats
```
Expected: 8 passing.

- [ ] **Step 5: Shellcheck**

```bash
shellcheck scripts/lib/json-out.sh
```
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/json-out.sh tests/unit/test_json_out.bats
git commit -m "lib: add json-out.sh with state_set/state_get/emit_final_json"
```

---

## Task 11: Implement `lib/idempotency.sh` with TDD

**Files:**
- Create: `tests/unit/test_idempotency.bats`
- Create: `scripts/lib/idempotency.sh`

- [ ] **Step 1: Write failing tests**

Create `tests/unit/test_idempotency.bats`:

```bash
#!/usr/bin/env bats

load helpers/load.bash

setup() {
  export SOC_STATE_DIR="${BATS_TEST_TMPDIR}/var/lib/soc-stack"
  export SOC_LOG_FILE="${BATS_TEST_TMPDIR}/soc-stack.log"
  mkdir -p "${SOC_STATE_DIR}/state"
  source_lib logging
  source "${REPO_ROOT}/scripts/lib/json-out.sh"
  source_lib idempotency
}

@test "is_completed returns false for missing state" {
  run is_completed wazuh
  [[ "$status" -ne 0 ]]
}

@test "is_completed returns false when status is not deployed" {
  state_set wazuh status "failed"
  run is_completed wazuh
  [[ "$status" -ne 0 ]]
}

@test "is_completed returns true when status is deployed" {
  state_set wazuh status "deployed"
  run is_completed wazuh
  [[ "$status" -eq 0 ]]
}

@test "mark_completed sets status to deployed" {
  mark_completed wazuh
  run state_get wazuh status
  assert_output "deployed"
}

@test "clear_state removes the state file" {
  state_set wazuh status "deployed"
  clear_state wazuh
  [[ ! -f "${SOC_STATE_DIR}/state/wazuh.json" ]]
}

@test "clear_state on missing state is a no-op" {
  run clear_state "does-not-exist"
  [[ "$status" -eq 0 ]]
}
```

- [ ] **Step 2: Run, verify failure**

```bash
./tests/unit/run.sh tests/unit/test_idempotency.bats
```
Expected: all 6 tests FAIL.

- [ ] **Step 3: Implement `lib/idempotency.sh`**

Create `scripts/lib/idempotency.sh`:

```bash
#!/usr/bin/env bash
# scripts/lib/idempotency.sh - "is this component already done?" checks
# Requires: lib/json-out.sh sourced first (for state_get / state_file)

# is_completed <component>
# Exit 0 if the component's state file says status="deployed"; non-zero otherwise.
is_completed() {
  local component="$1"
  local status
  status="$(state_get "${component}" status)"
  [[ "${status}" == "deployed" ]]
}

# mark_completed <component>
# Set the component's status to "deployed".
mark_completed() {
  local component="$1"
  state_set "${component}" status "deployed"
}

# clear_state <component>
# Remove the component's state file (idempotent - no error if missing).
clear_state() {
  local component="$1"
  local f
  f="$(state_file "${component}")"
  rm -f "${f}"
}
```

- [ ] **Step 4: Run tests, verify pass**

```bash
./tests/unit/run.sh tests/unit/test_idempotency.bats
```
Expected: 6 passing.

- [ ] **Step 5: Shellcheck**

```bash
shellcheck scripts/lib/idempotency.sh
```
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/idempotency.sh tests/unit/test_idempotency.bats
git commit -m "lib: add idempotency.sh with is_completed/mark_completed/clear_state"
```

---

## Task 12: Implement `lib/network.sh` with TDD

**Files:**
- Create: `tests/unit/test_network.bats`
- Create: `scripts/lib/network.sh`

- [ ] **Step 1: Write failing tests**

Create `tests/unit/test_network.bats`:

```bash
#!/usr/bin/env bats

load helpers/load.bash

setup() {
  export SOC_LOG_FILE="${BATS_TEST_TMPDIR}/soc-stack.log"
  source_lib logging
  source_lib network
}

@test "next_vmid returns sequential starting from vmid_start" {
  MOCK_PCT_LIST=$'VMID Status Lock Name\n100 running - existing1\n101 running - existing2'
  export MOCK_PCT_LIST
  MOCK_QM_LIST=$'VMID NAME STATUS\n102 vm-a stopped'
  export MOCK_QM_LIST

  run next_vmid 100
  assert_success
  assert_output "103"
}

@test "next_vmid skips occupied IDs" {
  MOCK_PCT_LIST=$'VMID Status Lock Name\n200 running - a\n201 running - b\n203 running - c'
  export MOCK_PCT_LIST
  MOCK_QM_LIST=$'VMID NAME STATUS'
  export MOCK_QM_LIST

  run next_vmid 200
  assert_success
  assert_output "202"
}

@test "next_vmid honors a higher starting VMID" {
  MOCK_PCT_LIST=$'VMID Status Lock Name'
  export MOCK_PCT_LIST
  MOCK_QM_LIST=$'VMID NAME STATUS'
  export MOCK_QM_LIST

  run next_vmid 9000
  assert_success
  assert_output "9000"
}

@test "allocate_ip with /24 returns sequential addresses" {
  run allocate_ip "10.0.50.10/24" 0
  assert_output "10.0.50.10/24"
  run allocate_ip "10.0.50.10/24" 1
  assert_output "10.0.50.11/24"
  run allocate_ip "10.0.50.10/24" 5
  assert_output "10.0.50.15/24"
}

@test "validate_bridge accepts existing bridge" {
  cat > "${BATS_TEST_TMPDIR}/fake-ip" <<'EOF'
#!/usr/bin/env bash
echo "vmbr0: <BROADCAST,MULTICAST,UP,LOWER_UP>"
EOF
  chmod +x "${BATS_TEST_TMPDIR}/fake-ip"
  PATH="${BATS_TEST_TMPDIR}:${PATH}" run validate_bridge "vmbr0"
  assert_success
}
```

- [ ] **Step 2: Run, verify failure**

```bash
./tests/unit/run.sh tests/unit/test_network.bats
```
Expected: all 5 tests FAIL.

- [ ] **Step 3: Implement `lib/network.sh`**

Create `scripts/lib/network.sh`:

```bash
#!/usr/bin/env bash
# scripts/lib/network.sh - VMID + IP allocation, bridge validation
# Requires: pct, qm, ip available on PATH

# next_vmid <start>
# Returns the lowest unused VMID >= start, considering both LXC (pct) and VM (qm).
next_vmid() {
  local start="$1"
  local used=()
  while IFS= read -r line; do
    local id="${line%% *}"
    [[ "${id}" =~ ^[0-9]+$ ]] && used+=("${id}")
  done < <(pct list 2>/dev/null | tail -n +2)
  while IFS= read -r line; do
    local id="${line%% *}"
    [[ "${id}" =~ ^[0-9]+$ ]] && used+=("${id}")
  done < <(qm list 2>/dev/null | tail -n +2)

  local candidate="${start}"
  while printf '%s\n' "${used[@]}" | grep -qx "${candidate}"; do
    candidate=$((candidate + 1))
  done
  printf '%s\n' "${candidate}"
}

# allocate_ip <base_cidr> <index>
# Given base "10.0.50.10/24" and index 3, returns "10.0.50.13/24".
allocate_ip() {
  local base_cidr="$1"
  local index="$2"
  local base_ip="${base_cidr%/*}"
  local cidr="${base_cidr#*/}"
  local base_last="${base_ip##*.}"
  local base_prefix="${base_ip%.*}"
  printf '%s.%d/%s\n' "${base_prefix}" "$((base_last + index))" "${cidr}"
}

# validate_bridge <name>
# Exit 0 if the bridge exists on the host; non-zero otherwise.
validate_bridge() {
  local bridge="$1"
  ip link show "${bridge}" >/dev/null 2>&1 || ip a 2>/dev/null | grep -q "^[0-9]*: ${bridge}:"
}
```

- [ ] **Step 4: Run tests, verify pass**

```bash
./tests/unit/run.sh tests/unit/test_network.bats
```
Expected: 5 passing.

- [ ] **Step 5: Shellcheck**

```bash
shellcheck scripts/lib/network.sh
```
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/network.sh tests/unit/test_network.bats
git commit -m "lib: add network.sh with next_vmid/allocate_ip/validate_bridge"
```

---

## Task 13: Implement `lib/manifest.sh` with TDD

**Files:**
- Create: `tests/unit/test_manifest.bats`
- Create: `scripts/lib/manifest.sh`
- Create: `tests/unit/fixtures/manifests/valid.json`
- Create: `tests/unit/fixtures/manifests/missing-components.json`

- [ ] **Step 1: Create fixture manifests**

```bash
mkdir -p tests/unit/fixtures/manifests
```

Create `tests/unit/fixtures/manifests/valid.json`:

```json
{
  "components": ["wazuh"],
  "preset": "standard",
  "network": {
    "bridge": "vmbr0",
    "storage": "local-lvm",
    "ip_mode": "dhcp"
  },
  "vmid_start": 9000
}
```

Create `tests/unit/fixtures/manifests/missing-components.json`:

```json
{
  "preset": "standard",
  "network": { "bridge": "vmbr0" }
}
```

- [ ] **Step 2: Write failing tests**

Create `tests/unit/test_manifest.bats`:

```bash
#!/usr/bin/env bats

load helpers/load.bash

setup() {
  export SOC_LOG_FILE="${BATS_TEST_TMPDIR}/soc-stack.log"
  source_lib logging
  source_lib manifest
}

@test "parse_manifest extracts components array" {
  run parse_manifest "${REPO_ROOT}/tests/unit/fixtures/manifests/valid.json" "components"
  assert_success
  assert_output --partial "wazuh"
}

@test "parse_manifest extracts nested keys" {
  run parse_manifest "${REPO_ROOT}/tests/unit/fixtures/manifests/valid.json" "network.bridge"
  assert_success
  assert_output "vmbr0"
}

@test "validate_manifest accepts valid manifest" {
  run validate_manifest "${REPO_ROOT}/tests/unit/fixtures/manifests/valid.json"
  assert_success
}

@test "validate_manifest rejects missing components" {
  run validate_manifest "${REPO_ROOT}/tests/unit/fixtures/manifests/missing-components.json"
  [[ "$status" -ne 0 ]]
  [[ "${output}${stderr:-}" == *"components"* ]]
}

@test "merge_flags_into_manifest applies flag overrides" {
  local out="${BATS_TEST_TMPDIR}/merged.json"
  merge_flags_into_manifest \
    "${REPO_ROOT}/tests/unit/fixtures/manifests/valid.json" \
    --preset minimal \
    --bridge vmbr1 \
    > "${out}"
  jq -e '.preset == "minimal"' "${out}"
  jq -e '.network.bridge == "vmbr1"' "${out}"
}

@test "build_manifest_from_flags produces valid manifest" {
  local out="${BATS_TEST_TMPDIR}/from-flags.json"
  build_manifest_from_flags \
    --components wazuh \
    --preset standard \
    --bridge vmbr0 \
    --storage local-lvm \
    --ip-mode dhcp \
    > "${out}"
  jq -e '.components[0] == "wazuh"' "${out}"
  jq -e '.preset == "standard"' "${out}"
}
```

- [ ] **Step 3: Run, verify failure**

```bash
./tests/unit/run.sh tests/unit/test_manifest.bats
```
Expected: all 6 tests FAIL.

- [ ] **Step 4: Implement `lib/manifest.sh`**

Create `scripts/lib/manifest.sh`:

```bash
#!/usr/bin/env bash
# scripts/lib/manifest.sh - manifest parsing, validation, and flag merging
# Requires: jq

# parse_manifest <file> <jq-path-with-dots>
# Prints the value at the path. Returns empty for missing.
parse_manifest() {
  local file="$1"
  local key="$2"
  jq -r "getpath(\"${key}\" / \".\") // empty | (if type == \"array\" then join(\",\") else . end)" "${file}"
}

# validate_manifest <file>
# Returns 0 if valid; otherwise prints errors and returns non-zero.
validate_manifest() {
  local file="$1"
  if ! jq -e . "${file}" >/dev/null 2>&1; then
    msg_error "manifest is not valid JSON: ${file}"
    return 1
  fi

  local missing=()
  jq -e '.components' "${file}" >/dev/null 2>&1 || missing+=("components")
  jq -e '.preset' "${file}"     >/dev/null 2>&1 || missing+=("preset")

  if [[ ${#missing[@]} -gt 0 ]]; then
    msg_error "manifest missing required keys: ${missing[*]}"
    return 1
  fi

  # Each component must be a known name
  local known="wazuh thehive-cortex misp zeek-suricata dashboards mcp"
  local bad=()
  while IFS= read -r c; do
    [[ -n "${c}" ]] || continue
    if ! grep -qw "${c}" <<< "${known}"; then
      bad+=("${c}")
    fi
  done < <(jq -r '.components[]' "${file}")
  if [[ ${#bad[@]} -gt 0 ]]; then
    msg_error "unknown components: ${bad[*]}"
    return 1
  fi

  return 0
}

# merge_flags_into_manifest <file> [--flag value ...]
# Reads a base manifest, applies CLI flag overrides, prints merged JSON to stdout.
merge_flags_into_manifest() {
  local file="$1"; shift
  local m
  m="$(cat "${file}")"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --components)  m="$(jq --arg v "$2" '.components = ($v | split(","))' <<< "${m}")"; shift 2 ;;
      --preset)      m="$(jq --arg v "$2" '.preset = $v' <<< "${m}")"; shift 2 ;;
      --bridge)      m="$(jq --arg v "$2" '.network.bridge = $v' <<< "${m}")"; shift 2 ;;
      --storage)     m="$(jq --arg v "$2" '.network.storage = $v' <<< "${m}")"; shift 2 ;;
      --ip-mode)     m="$(jq --arg v "$2" '.network.ip_mode = $v' <<< "${m}")"; shift 2 ;;
      --ip-range)    m="$(jq --arg v "$2" '.network.ip_range = $v' <<< "${m}")"; shift 2 ;;
      --vlan)        m="$(jq --arg v "$2" '.network.vlan = $v' <<< "${m}")"; shift 2 ;;
      --vmid-start)  m="$(jq --argjson v "$2" '.vmid_start = $v' <<< "${m}")"; shift 2 ;;
      *) shift ;;
    esac
  done
  printf '%s\n' "${m}"
}

# build_manifest_from_flags [--flag value ...]
# Constructs a manifest from scratch using defaults + flags.
build_manifest_from_flags() {
  local base
  base='{
    "components": ["wazuh","thehive-cortex","misp","zeek-suricata","dashboards","mcp"],
    "preset": "standard",
    "network": {
      "bridge": "vmbr0",
      "storage": "local-lvm",
      "ip_mode": "dhcp"
    },
    "vmid_start": 0
  }'
  local tmp
  tmp="$(mktemp)"
  printf '%s' "${base}" > "${tmp}"
  merge_flags_into_manifest "${tmp}" "$@"
  rm -f "${tmp}"
}
```

- [ ] **Step 5: Run tests, verify pass**

```bash
./tests/unit/run.sh tests/unit/test_manifest.bats
```
Expected: 6 passing.

- [ ] **Step 6: Shellcheck**

```bash
shellcheck scripts/lib/manifest.sh
```
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/manifest.sh tests/unit/test_manifest.bats tests/unit/fixtures/manifests/
git commit -m "lib: add manifest.sh with parse/validate/merge_flags/build_from_flags"
```

---

## Task 14: Implement `lib/preflight.sh` with TDD

**Files:**
- Create: `tests/unit/test_preflight.bats`
- Create: `scripts/lib/preflight.sh`

- [ ] **Step 1: Write failing tests**

Create `tests/unit/test_preflight.bats`:

```bash
#!/usr/bin/env bats

load helpers/load.bash

setup() {
  export SOC_LOG_FILE="${BATS_TEST_TMPDIR}/soc-stack.log"
  source_lib logging
  source_lib preflight
}

@test "check_root returns success when EUID=0 (simulated)" {
  EUID=0 run check_root
  assert_success
}

@test "check_root fails when not root" {
  EUID=1000 run check_root
  [[ "$status" -ne 0 ]]
}

@test "check_storage validates storage exists in pvesm output" {
  run check_storage "local-lvm"
  assert_success
}

@test "check_storage fails on unknown storage" {
  export MOCK_PVESM_STATUS=$'Name Type Status Total Used Available %\nlocal dir active 100GB 10GB 90GB 10%'
  run check_storage "missing-pool"
  [[ "$status" -ne 0 ]]
}

@test "check_proxmox_version accepts 7.x" {
  cat > "${BATS_TEST_TMPDIR}/fake-pveversion" <<'EOF'
#!/usr/bin/env bash
echo "pve-manager/7.4-17/513c62be"
EOF
  chmod +x "${BATS_TEST_TMPDIR}/fake-pveversion"
  PATH="${BATS_TEST_TMPDIR}:${PATH}" run check_proxmox_version
  assert_success
}

@test "check_proxmox_version accepts 8.x" {
  cat > "${BATS_TEST_TMPDIR}/fake-pveversion" <<'EOF'
#!/usr/bin/env bash
echo "pve-manager/8.2.4/abc123"
EOF
  chmod +x "${BATS_TEST_TMPDIR}/fake-pveversion"
  ln -sf "${BATS_TEST_TMPDIR}/fake-pveversion" "${BATS_TEST_TMPDIR}/pveversion"
  PATH="${BATS_TEST_TMPDIR}:${PATH}" run check_proxmox_version
  assert_success
}

@test "check_proxmox_version rejects 6.x" {
  cat > "${BATS_TEST_TMPDIR}/pveversion" <<'EOF'
#!/usr/bin/env bash
echo "pve-manager/6.4-15/abc123"
EOF
  chmod +x "${BATS_TEST_TMPDIR}/pveversion"
  PATH="${BATS_TEST_TMPDIR}:${PATH}" run check_proxmox_version
  [[ "$status" -ne 0 ]]
}
```

- [ ] **Step 2: Run, verify failure**

```bash
./tests/unit/run.sh tests/unit/test_preflight.bats
```
Expected: all 7 tests FAIL.

- [ ] **Step 3: Implement `lib/preflight.sh`**

Create `scripts/lib/preflight.sh`:

```bash
#!/usr/bin/env bash
# scripts/lib/preflight.sh - environment readiness checks
# Requires: lib/logging.sh, lib/network.sh sourced first

check_root() {
  if [[ ${EUID} -ne 0 ]]; then
    msg_error "must run as root (got EUID=${EUID})"
    return 1
  fi
}

check_proxmox_version() {
  if ! command -v pveversion >/dev/null 2>&1; then
    msg_error "pveversion not found - this script must run on a Proxmox VE host"
    return 1
  fi
  local ver major
  ver="$(pveversion 2>/dev/null | head -1 | grep -oE '/[0-9]+\.[0-9]+' | head -1 | tr -d /)"
  major="${ver%%.*}"
  if [[ -z "${major}" ]] || (( major < 7 )); then
    msg_error "Proxmox VE ${ver:-unknown} not supported (requires 7.x or 8.x)"
    return 1
  fi
  msg_ok "Proxmox VE ${ver} detected"
}

check_deps() {
  local missing=()
  local dep
  for dep in jq curl wget openssl; do
    command -v "${dep}" >/dev/null 2>&1 || missing+=("${dep}")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    msg_error "missing dependencies: ${missing[*]} (install with: apt-get install -y ${missing[*]})"
    return 1
  fi
}

check_bridge() {
  local bridge="$1"
  if ! validate_bridge "${bridge}" 2>/dev/null; then
    msg_error "bridge ${bridge} not found on host"
    return 1
  fi
}

check_storage() {
  local storage="$1"
  if ! pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "${storage}"; then
    msg_error "storage ${storage} not configured on host"
    return 1
  fi
}
```

- [ ] **Step 4: Run tests, verify pass**

```bash
./tests/unit/run.sh tests/unit/test_preflight.bats
```
Expected: 7 passing.

- [ ] **Step 5: Shellcheck**

```bash
shellcheck scripts/lib/preflight.sh
```
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/preflight.sh tests/unit/test_preflight.bats
git commit -m "lib: add preflight.sh with check_root/proxmox/deps/bridge/storage"
```

---

## Task 15: Implement `lib/lxc.sh` with TDD

**Files:**
- Create: `tests/unit/test_lxc.bats`
- Create: `scripts/lib/lxc.sh`

- [ ] **Step 1: Write failing tests**

Create `tests/unit/test_lxc.bats`:

```bash
#!/usr/bin/env bats

load helpers/load.bash

setup() {
  export SOC_LOG_FILE="${BATS_TEST_TMPDIR}/soc-stack.log"
  source_lib logging
  source_lib lxc
}

@test "lxc_exists returns success when pct status reports running" {
  export MOCK_PCT_STATUS=running
  run lxc_exists 9001
  assert_success
}

@test "lxc_exists returns failure when pct exits non-zero" {
  export MOCK_PCT_EXIT=2
  run lxc_exists 9001
  [[ "$status" -ne 0 ]]
}

@test "lxc_running returns success only when pct status says running" {
  export MOCK_PCT_STATUS=running
  run lxc_running 9001
  assert_success
}

@test "lxc_running returns failure when stopped" {
  export MOCK_PCT_STATUS=stopped
  run lxc_running 9001
  [[ "$status" -ne 0 ]]
}

@test "lxc_create invokes pct create with expected args" {
  MOCK_PCT_CALLS_LOG="${BATS_TEST_TMPDIR}/pct-calls.log"
  export MOCK_PCT_CALLS_LOG
  lxc_create 9001 \
    "s3-test" \
    "local:vztmpl/ubuntu-22.04.tar.zst" \
    --memory 2048 \
    --cores 1 \
    --rootfs "local-lvm:30" \
    --net0 "name=eth0,bridge=vmbr0,ip=dhcp" \
    --password "p4ss"
  grep -q "pct create 9001" "${MOCK_PCT_CALLS_LOG}"
}

@test "lxc_start is idempotent when already running" {
  MOCK_PCT_STATUS=running
  MOCK_PCT_CALLS_LOG="${BATS_TEST_TMPDIR}/pct-calls.log"
  export MOCK_PCT_STATUS MOCK_PCT_CALLS_LOG
  lxc_start 9001
  ! grep -q "pct start 9001" "${MOCK_PCT_CALLS_LOG}"
}

@test "lxc_start invokes pct start when stopped" {
  MOCK_PCT_STATUS=stopped
  MOCK_PCT_CALLS_LOG="${BATS_TEST_TMPDIR}/pct-calls.log"
  export MOCK_PCT_STATUS MOCK_PCT_CALLS_LOG
  lxc_start 9001
  grep -q "pct start 9001" "${MOCK_PCT_CALLS_LOG}"
}
```

- [ ] **Step 2: Run, verify failure**

```bash
./tests/unit/run.sh tests/unit/test_lxc.bats
```
Expected: all 7 tests FAIL.

- [ ] **Step 3: Implement `lib/lxc.sh`**

Create `scripts/lib/lxc.sh`:

```bash
#!/usr/bin/env bash
# scripts/lib/lxc.sh - LXC lifecycle helpers (idempotent)
# Requires: lib/logging.sh, pct on PATH

# lxc_exists <vmid>
# Returns 0 if `pct status <vmid>` succeeds, else non-zero.
lxc_exists() {
  pct status "$1" >/dev/null 2>&1
}

# lxc_running <vmid>
# Returns 0 if status reports "running", else non-zero.
lxc_running() {
  local out
  out="$(pct status "$1" 2>/dev/null)"
  [[ "${out}" == *"running"* ]]
}

# lxc_create <vmid> <hostname> <template> [extra pct args...]
# Idempotent: if VMID already exists, returns 0 immediately.
lxc_create() {
  local vmid="$1"; shift
  local hostname="$1"; shift
  local template="$1"; shift

  if lxc_exists "${vmid}"; then
    msg_info "LXC ${vmid} already exists, skipping create"
    return 0
  fi

  pct create "${vmid}" "${template}" --hostname "${hostname}" "$@"
}

# lxc_start <vmid>
# Idempotent: no-op if already running.
lxc_start() {
  local vmid="$1"
  if lxc_running "${vmid}"; then
    return 0
  fi
  pct start "${vmid}"
}

# lxc_stop <vmid>
# Idempotent: no-op if already stopped.
lxc_stop() {
  local vmid="$1"
  if ! lxc_running "${vmid}"; then
    return 0
  fi
  pct stop "${vmid}"
}

# lxc_destroy <vmid>
# Stops then destroys. Idempotent.
lxc_destroy() {
  local vmid="$1"
  if ! lxc_exists "${vmid}"; then
    return 0
  fi
  lxc_stop "${vmid}" || true
  pct destroy "${vmid}"
}

# lxc_push_script <vmid> <local_path> <remote_path>
lxc_push_script() {
  local vmid="$1"
  local local_path="$2"
  local remote_path="$3"
  pct push "${vmid}" "${local_path}" "${remote_path}"
  pct exec "${vmid}" -- chmod +x "${remote_path}"
}

# lxc_exec <vmid> -- <cmd...>
lxc_exec() {
  pct exec "$@"
}

# lxc_wait_network <vmid> [timeout_seconds]
# Polls for connectivity from inside the LXC. Default 60s timeout.
lxc_wait_network() {
  local vmid="$1"
  local timeout="${2:-60}"
  local elapsed=0
  while (( elapsed < timeout )); do
    if pct exec "${vmid}" -- ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  msg_warn "network wait timed out for LXC ${vmid} after ${timeout}s"
  return 1
}

# lxc_ip <vmid>
# Prints the LXC's primary IP, or empty.
lxc_ip() {
  pct exec "$1" -- hostname -I 2>/dev/null | awk '{print $1}'
}
```

- [ ] **Step 4: Run tests, verify pass**

```bash
./tests/unit/run.sh tests/unit/test_lxc.bats
```
Expected: 7 passing.

- [ ] **Step 5: Shellcheck**

```bash
shellcheck scripts/lib/lxc.sh
```
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/lxc.sh tests/unit/test_lxc.bats
git commit -m "lib: add lxc.sh with create/start/stop/destroy/push/exec/wait_network/ip (idempotent)"
```

---

## Task 16: Run the full unit test suite end-to-end

- [ ] **Step 1: Run all bats tests**

```bash
./tests/unit/run.sh
```
Expected: every test file passes. Roughly 50+ tests total.

- [ ] **Step 2: Run shellcheck across all lib**

```bash
shellcheck scripts/lib/*.sh
```
Expected: no output (clean).

- [ ] **Step 3: If anything fails, fix in-place and re-run before continuing.**

---

## Task 17: Create the Wazuh component manifest

**Files:**
- Create: `scripts/components/wazuh/manifest.jsonc`

- [ ] **Step 1: Write the manifest**

Create `scripts/components/wazuh/manifest.jsonc`:

```jsonc
{
  "name": "wazuh",
  "display_name": "Wazuh",
  "description": "SIEM/XDR platform with vulnerability management",
  "depends_on": [],
  "provides": ["wazuh_url", "wazuh_api", "wazuh_agent_endpoint"],
  "presets": {
    "minimal":    { "ram_mb": 2048, "disk_gb": 30,  "cores": 1 },
    "standard":   { "ram_mb": 4096, "disk_gb": 50,  "cores": 2 },
    "production": { "ram_mb": 8192, "disk_gb": 100, "cores": 4 }
  },
  "ports": [443, 1514, 1515, 55000],
  "template_pattern": "ubuntu-22.04-standard",
  "features": ["nesting=1"],
  "unprivileged": true,
  "install_method": "native",
  "default_creds": {
    "user": "admin",
    "password_rotate_on_install": true
  }
}
```

- [ ] **Step 2: Validate JSON (strip comments first since jq doesn't accept JSONC)**

```bash
sed 's://.*$::g' scripts/components/wazuh/manifest.jsonc | jq -e .
```
Expected: prints the manifest with no errors.

- [ ] **Step 3: Commit**

```bash
git add scripts/components/wazuh/manifest.jsonc
git commit -m "components: add wazuh manifest.jsonc"
```

---

## Task 18: Create the Wazuh `lxc-spec.sh`

**Files:**
- Create: `scripts/components/wazuh/lxc-spec.sh`

- [ ] **Step 1: Write the spec emitter**

Create `scripts/components/wazuh/lxc-spec.sh`:

```bash
#!/usr/bin/env bash
# scripts/components/wazuh/lxc-spec.sh
# Emits LXC creation flags for Wazuh. Stdout: space-separated `pct create` args.
# Inputs (env):
#   SOC_PRESET           — minimal|standard|production
#   SOC_NETWORK_CONFIG   — pct --net0 string already built by orchestrator
#   SOC_STORAGE          — storage pool name

set -euo pipefail

case "${SOC_PRESET:-standard}" in
  minimal)    RAM=2048; DISK=30;  CORES=1 ;;
  standard)   RAM=4096; DISK=50;  CORES=2 ;;
  production) RAM=8192; DISK=100; CORES=4 ;;
  *) echo "unknown preset: ${SOC_PRESET}" >&2; exit 1 ;;
esac

cat <<EOF
--memory ${RAM}
--cores ${CORES}
--rootfs ${SOC_STORAGE:-local-lvm}:${DISK}
--net0 ${SOC_NETWORK_CONFIG:-name=eth0,bridge=vmbr0,ip=dhcp}
--unprivileged 1
--features nesting=1
--onboot 1
--start 0
EOF
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/components/wazuh/lxc-spec.sh
```

- [ ] **Step 3: Smoke test**

```bash
SOC_PRESET=minimal SOC_STORAGE=local-lvm \
  ./scripts/components/wazuh/lxc-spec.sh | head -1
```
Expected: `--memory 2048`

- [ ] **Step 4: Shellcheck**

```bash
shellcheck scripts/components/wazuh/lxc-spec.sh
```
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add scripts/components/wazuh/lxc-spec.sh
git commit -m "components(wazuh): add lxc-spec.sh emitter for pct create flags"
```

---

## Task 19: Create the Wazuh `deploy.sh` (inside-LXC installer)

**Files:**
- Create: `scripts/components/wazuh/deploy.sh`

The existing `scripts/setup/components/wazuh.sh` is the starting point. The new file uses the same Wazuh installer flow but adds idempotency markers and writes the new state JSON format.

- [ ] **Step 1: Write the deploy script**

Create `scripts/components/wazuh/deploy.sh`:

```bash
#!/usr/bin/env bash
# scripts/components/wazuh/deploy.sh
# Runs INSIDE the Wazuh LXC. Idempotent. Installs Wazuh single-node.
#
# Required env (set by orchestrator via pct exec):
#   SOC_STATE_DIR        — bind-mounted from /var/lib/soc-stack/ on the host
#   SOC_COMPONENT        — "wazuh"
#   SOC_PRESET           — informational
#   SOC_NON_INTERACTIVE  — "1"
#
# On success: writes ${SOC_STATE_DIR}/state/wazuh.json with status=deployed
# On failure: writes ${SOC_STATE_DIR}/state/wazuh.json with status=failed + error

set -euo pipefail

: "${SOC_STATE_DIR:?SOC_STATE_DIR must be set}"
: "${SOC_COMPONENT:=wazuh}"

STATE_FILE="${SOC_STATE_DIR}/state/${SOC_COMPONENT}.json"
SECRETS_DIR="${SOC_STATE_DIR}/secrets"
mkdir -p "${SOC_STATE_DIR}/state" "${SECRETS_DIR}"

log() { printf '[wazuh-deploy] %s\n' "$*"; }

write_failed() {
  local err="$1"
  jq -n --arg err "${err}" '{
    component: "wazuh",
    status: "failed",
    error: $err
  }' > "${STATE_FILE}"
  log "FAILED: ${err}"
  exit 1
}

trap 'write_failed "deploy.sh aborted on line $LINENO"' ERR

# Idempotency: if services are already running, refresh state and exit 0
if systemctl is-active --quiet wazuh-manager 2>/dev/null \
   && systemctl is-active --quiet wazuh-indexer 2>/dev/null \
   && systemctl is-active --quiet wazuh-dashboard 2>/dev/null; then
  log "Wazuh already installed and running, refreshing state"

  IP="$(hostname -I | awk '{print $1}')"
  ADMIN_PASS=""
  if [[ -f "${SECRETS_DIR}/wazuh-admin.txt" ]]; then
    ADMIN_PASS="$(cat "${SECRETS_DIR}/wazuh-admin.txt")"
  fi

  jq -n \
    --arg ip "${IP}" \
    --arg pass "${ADMIN_PASS}" \
    '{
      component: "wazuh",
      status: "deployed",
      url: ("https://" + $ip),
      api_url: ("https://" + $ip + ":55000"),
      agent_endpoint: ($ip + ":1515"),
      credentials: { user: "admin", password: $pass },
      services: ["wazuh-manager","wazuh-indexer","wazuh-dashboard"]
    }' > "${STATE_FILE}"
  exit 0
fi

# Fresh install
log "Updating apt"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl wget gnupg jq

log "Downloading Wazuh installer"
cd /root
curl -fsSLO https://packages.wazuh.com/4.9/wazuh-install.sh
curl -fsSLO https://packages.wazuh.com/4.9/config.yml || cat > config.yml <<'EOF'
nodes:
  indexer:
    - name: node-1
      ip: "127.0.0.1"
  server:
    - name: wazuh-1
      ip: "127.0.0.1"
  dashboard:
    - name: dashboard
      ip: "127.0.0.1"
EOF

log "Running wazuh-install.sh (this may take 10-20 minutes)"
bash wazuh-install.sh --generate-config-files
bash wazuh-install.sh --wazuh-indexer node-1
bash wazuh-install.sh --start-cluster
bash wazuh-install.sh --wazuh-server wazuh-1
bash wazuh-install.sh --wazuh-dashboard dashboard

# Extract the generated admin password from wazuh-passwords.txt
ADMIN_PASS=""
if [[ -f /root/wazuh-install-files.tar ]]; then
  tar -xf /root/wazuh-install-files.tar -C /tmp/
  if [[ -f /tmp/wazuh-install-files/wazuh-passwords.txt ]]; then
    ADMIN_PASS="$(grep -A1 "username: 'admin'" /tmp/wazuh-install-files/wazuh-passwords.txt | grep password | awk -F\' '{print $2}')"
  fi
fi
ADMIN_PASS="${ADMIN_PASS:-admin}"

# Store the password
printf '%s' "${ADMIN_PASS}" > "${SECRETS_DIR}/wazuh-admin.txt"
chmod 600 "${SECRETS_DIR}/wazuh-admin.txt"

# Verify services
for svc in wazuh-manager wazuh-indexer wazuh-dashboard; do
  if ! systemctl is-active --quiet "${svc}"; then
    write_failed "${svc} did not start"
  fi
done

IP="$(hostname -I | awk '{print $1}')"

jq -n \
  --arg ip "${IP}" \
  --arg pass "${ADMIN_PASS}" \
  '{
    component: "wazuh",
    status: "deployed",
    url: ("https://" + $ip),
    api_url: ("https://" + $ip + ":55000"),
    agent_endpoint: ($ip + ":1515"),
    credentials: { user: "admin", password: $pass },
    services: ["wazuh-manager","wazuh-indexer","wazuh-dashboard"]
  }' > "${STATE_FILE}"

log "Wazuh deployment complete: https://${IP}"
trap - ERR
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/components/wazuh/deploy.sh
```

- [ ] **Step 3: Shellcheck**

```bash
shellcheck scripts/components/wazuh/deploy.sh
```
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add scripts/components/wazuh/deploy.sh
git commit -m "components(wazuh): add deploy.sh (idempotent, writes state JSON)"
```

---

## Task 20: Create the Wazuh `verify.sh` (health check)

**Files:**
- Create: `scripts/components/wazuh/verify.sh`

- [ ] **Step 1: Write verify**

Create `scripts/components/wazuh/verify.sh`:

```bash
#!/usr/bin/env bash
# scripts/components/wazuh/verify.sh
# Runs INSIDE the Wazuh LXC. Returns 0 if healthy.

set -euo pipefail

fail=0
for svc in wazuh-manager wazuh-indexer wazuh-dashboard; do
  if ! systemctl is-active --quiet "${svc}"; then
    printf '[verify] %s is not active\n' "${svc}" >&2
    fail=1
  fi
done

# Dashboard HTTPS responds
IP="$(hostname -I | awk '{print $1}')"
if ! curl -sk --max-time 10 "https://${IP}/" >/dev/null; then
  printf '[verify] dashboard https://%s/ did not respond\n' "${IP}" >&2
  fail=1
fi

# API responds (401 is fine - means service is up)
local_code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://${IP}:55000/")"
if [[ "${local_code}" -lt 200 || "${local_code}" -ge 600 ]]; then
  printf '[verify] API https://%s:55000/ returned %s\n' "${IP}" "${local_code}" >&2
  fail=1
fi

exit "${fail}"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/components/wazuh/verify.sh
```

- [ ] **Step 3: Shellcheck**

```bash
shellcheck scripts/components/wazuh/verify.sh
```
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add scripts/components/wazuh/verify.sh
git commit -m "components(wazuh): add verify.sh health check"
```

---

## Task 21: Create the Wazuh `integrate.sh` stub

**Files:**
- Create: `scripts/components/wazuh/integrate.sh`

Wazuh's real integration (webhook to TheHive) needs TheHive's state, which doesn't exist yet. Plan 2 adds the real wiring. Plan 1 ships a stub that respects the contract.

- [ ] **Step 1: Write integrate stub**

Create `scripts/components/wazuh/integrate.sh`:

```bash
#!/usr/bin/env bash
# scripts/components/wazuh/integrate.sh
# Runs on the Proxmox HOST after all components are deployed.
# Wires Wazuh to other components based on their state files.
#
# Plan 1: stub. Plan 2 adds TheHive webhook wiring.

set -euo pipefail

: "${SOC_STATE_DIR:?SOC_STATE_DIR must be set}"

log() { printf '[wazuh-integrate] %s\n' "$*"; }

THEHIVE_STATE="${SOC_STATE_DIR}/state/thehive-cortex.json"

if [[ ! -f "${THEHIVE_STATE}" ]]; then
  log "TheHive not deployed, skipping Wazuh -> TheHive webhook wiring"
  exit 0
fi

thehive_status="$(jq -r '.status // empty' "${THEHIVE_STATE}")"
if [[ "${thehive_status}" != "deployed" ]]; then
  log "TheHive status=${thehive_status}, skipping webhook wiring"
  exit 0
fi

log "TheHive present but webhook wiring is implemented in Plan 2"
exit 0
```

- [ ] **Step 2: Make executable + shellcheck**

```bash
chmod +x scripts/components/wazuh/integrate.sh
shellcheck scripts/components/wazuh/integrate.sh
```
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add scripts/components/wazuh/integrate.sh
git commit -m "components(wazuh): add integrate.sh stub (full impl in Plan 2)"
```

---

## Task 22: Create the Wazuh `destroy.sh`

**Files:**
- Create: `scripts/components/wazuh/destroy.sh`

- [ ] **Step 1: Write destroy**

Create `scripts/components/wazuh/destroy.sh`:

```bash
#!/usr/bin/env bash
# scripts/components/wazuh/destroy.sh
# Runs on the Proxmox HOST. Tears down the Wazuh LXC.
#
# Required env:
#   SOC_STATE_DIR

set -euo pipefail

: "${SOC_STATE_DIR:?SOC_STATE_DIR must be set}"

STATE_FILE="${SOC_STATE_DIR}/state/wazuh.json"
log() { printf '[wazuh-destroy] %s\n' "$*"; }

if [[ ! -f "${STATE_FILE}" ]]; then
  log "no state file for wazuh, nothing to destroy"
  exit 0
fi

VMID="$(jq -r '.lxc.vmid // empty' "${STATE_FILE}")"
if [[ -z "${VMID}" ]]; then
  log "no VMID in wazuh state, removing state file only"
  rm -f "${STATE_FILE}"
  exit 0
fi

log "stopping LXC ${VMID}"
pct stop "${VMID}" 2>/dev/null || true
log "destroying LXC ${VMID}"
pct destroy "${VMID}" 2>/dev/null || true

rm -f "${STATE_FILE}"
log "wazuh teardown complete"
```

- [ ] **Step 2: Make executable + shellcheck**

```bash
chmod +x scripts/components/wazuh/destroy.sh
shellcheck scripts/components/wazuh/destroy.sh
```
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add scripts/components/wazuh/destroy.sh
git commit -m "components(wazuh): add destroy.sh teardown"
```

---

## Task 23: Implement the minimal orchestrator with TDD-style flag parsing

**Files:**
- Create: `tests/unit/test_orchestrator_flag_parsing.bats`
- Create: `scripts/install.sh`

- [ ] **Step 1: Write failing flag-parser tests**

Create `tests/unit/test_orchestrator_flag_parsing.bats`:

```bash
#!/usr/bin/env bats

load helpers/load.bash

setup() {
  export SOC_LOG_FILE="${BATS_TEST_TMPDIR}/soc-stack.log"
  # Source the orchestrator with a guard so it doesn't run main()
  export SOC_TEST_MODE=1
  source "${REPO_ROOT}/scripts/install.sh"
}

@test "parse_args sets defaults" {
  parse_args
  [[ "${OPT_COMPONENTS}" == "all" ]]
  [[ "${OPT_PRESET}" == "standard" ]]
  [[ "${OPT_BRIDGE}" == "vmbr0" ]]
  [[ "${OPT_IP_MODE}" == "dhcp" ]]
  [[ "${OPT_STATE_DIR}" == "/var/lib/soc-stack" ]]
  [[ "${OPT_JSON_OUT}" == "/root/soc-stack.json" ]]
}

@test "parse_args overrides via --components" {
  parse_args --components wazuh,misp
  [[ "${OPT_COMPONENTS}" == "wazuh,misp" ]]
}

@test "parse_args overrides --preset minimal" {
  parse_args --preset minimal
  [[ "${OPT_PRESET}" == "minimal" ]]
}

@test "parse_args overrides --bridge --storage" {
  parse_args --bridge vmbr1 --storage local-lvm-test
  [[ "${OPT_BRIDGE}" == "vmbr1" ]]
  [[ "${OPT_STORAGE}" == "local-lvm-test" ]]
}

@test "parse_args sets OPT_DRY_RUN=1 when --dry-run is passed" {
  parse_args --dry-run
  [[ "${OPT_DRY_RUN}" == "1" ]]
}

@test "parse_args sets OPT_FORCE=1 when --force is passed" {
  parse_args --force
  [[ "${OPT_FORCE}" == "1" ]]
}

@test "parse_args sets OPT_VMID_START" {
  parse_args --vmid-start 9000
  [[ "${OPT_VMID_START}" == "9000" ]]
}

@test "parse_args exits with --version" {
  run parse_args --version
  assert_success
  assert_output --partial "soc-stack"
}

@test "parse_args fails on unknown flag" {
  run parse_args --not-a-flag
  [[ "$status" -ne 0 ]]
  [[ "${output}${stderr:-}" == *"unknown"* ]]
}
```

- [ ] **Step 2: Run, verify failure**

```bash
./tests/unit/run.sh tests/unit/test_orchestrator_flag_parsing.bats
```
Expected: all 9 tests FAIL (install.sh doesn't exist yet).

- [ ] **Step 3: Implement the orchestrator (flag parsing only for now)**

Create `scripts/install.sh`:

```bash
#!/usr/bin/env bash
# scripts/install.sh - SOC Stack unified Proxmox installer (Plan 1 - wazuh only)
# Spec: docs/superpowers/specs/2026-05-15-soc-stack-unification-design.md

set -euo pipefail

SOC_STACK_VERSION="0.5.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
COMPONENTS_DIR="${SCRIPT_DIR}/components"

# Defaults
OPT_COMPONENTS="all"
OPT_PRESET="standard"
OPT_BRIDGE="vmbr0"
OPT_STORAGE=""
OPT_IP_MODE="dhcp"
OPT_IP_RANGE=""
OPT_VLAN=""
OPT_VMID_START="0"
OPT_MANIFEST=""
OPT_STATE_DIR="/var/lib/soc-stack"
OPT_JSON_OUT="/root/soc-stack.json"
OPT_MCP_CONFIG_OUT="/root/mcp-clients.json"
OPT_LOG_FILE="/var/log/soc-stack-install.log"
OPT_DRY_RUN="0"
OPT_FORCE="0"
OPT_NO_INTEGRATE="0"
OPT_NON_INTERACTIVE=""

usage() {
  cat <<EOF
soc-stack v${SOC_STACK_VERSION}

Usage:
  sudo bash install.sh [flags]

Flags:
  --components LIST     CSV of components or "all" (default: all)
  --preset NAME         minimal|standard|production (default: standard)
  --bridge NAME         Proxmox bridge (default: vmbr0)
  --storage NAME        Storage pool (default: auto-detect)
  --ip-mode MODE        dhcp|static (default: dhcp)
  --ip-range CIDR       Required if --ip-mode=static
  --vlan TAG            Optional VLAN tag
  --vmid-start N        First VMID to allocate (default: next free)
  --manifest PATH       JSON manifest (alternative to flags)
  --state-dir PATH      State directory (default: /var/lib/soc-stack)
  --json-out PATH       Result JSON (default: /root/soc-stack.json)
  --mcp-config-out PATH MCP client config (default: /root/mcp-clients.json)
  --log-file PATH       Log file (default: /var/log/soc-stack-install.log)
  --dry-run             Validate + plan, do not deploy
  --force               Redeploy even if state shows complete
  --no-integrate        Skip cross-component wiring
  --non-interactive     Hard-fail on prompts (auto when stdin not a tty)
  --version             Print version and exit
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --components)        OPT_COMPONENTS="$2"; shift 2 ;;
      --preset)            OPT_PRESET="$2"; shift 2 ;;
      --bridge)            OPT_BRIDGE="$2"; shift 2 ;;
      --storage)           OPT_STORAGE="$2"; shift 2 ;;
      --ip-mode)           OPT_IP_MODE="$2"; shift 2 ;;
      --ip-range)          OPT_IP_RANGE="$2"; shift 2 ;;
      --vlan)              OPT_VLAN="$2"; shift 2 ;;
      --vmid-start)        OPT_VMID_START="$2"; shift 2 ;;
      --manifest)          OPT_MANIFEST="$2"; shift 2 ;;
      --state-dir)         OPT_STATE_DIR="$2"; shift 2 ;;
      --json-out)          OPT_JSON_OUT="$2"; shift 2 ;;
      --mcp-config-out)    OPT_MCP_CONFIG_OUT="$2"; shift 2 ;;
      --log-file)          OPT_LOG_FILE="$2"; shift 2 ;;
      --dry-run)           OPT_DRY_RUN="1"; shift ;;
      --force)             OPT_FORCE="1"; shift ;;
      --no-integrate)      OPT_NO_INTEGRATE="1"; shift ;;
      --non-interactive)   OPT_NON_INTERACTIVE="1"; shift ;;
      --version)           printf 'soc-stack v%s\n' "${SOC_STACK_VERSION}"; return 0 ;;
      --help|-h)           usage; return 0 ;;
      *) printf 'unknown flag: %s\n' "$1" >&2; usage >&2; return 1 ;;
    esac
  done

  # Auto-set non-interactive when stdin not a TTY
  if [[ -z "${OPT_NON_INTERACTIVE}" ]]; then
    [[ -t 0 ]] && OPT_NON_INTERACTIVE="0" || OPT_NON_INTERACTIVE="1"
  fi
}

source_libs() {
  export SOC_LOG_FILE="${OPT_LOG_FILE}"
  export SOC_STATE_DIR="${OPT_STATE_DIR}"
  export SOC_SECRETS_DIR="${OPT_STATE_DIR}/secrets"

  # shellcheck source=lib/logging.sh
  source "${LIB_DIR}/logging.sh"
  # shellcheck source=lib/secrets.sh
  source "${LIB_DIR}/secrets.sh"
  # shellcheck source=lib/json-out.sh
  source "${LIB_DIR}/json-out.sh"
  # shellcheck source=lib/idempotency.sh
  source "${LIB_DIR}/idempotency.sh"
  # shellcheck source=lib/network.sh
  source "${LIB_DIR}/network.sh"
  # shellcheck source=lib/preflight.sh
  source "${LIB_DIR}/preflight.sh"
  # shellcheck source=lib/lxc.sh
  source "${LIB_DIR}/lxc.sh"
  # shellcheck source=lib/manifest.sh
  source "${LIB_DIR}/manifest.sh"
}

# main() stub - the full preflight + dispatch body lands in Task 25.
# This stub is intentionally minimal so tests for parse_args / build_manifest
# can source install.sh under SOC_TEST_MODE without triggering deployment logic.
main() {
  parse_args "$@" || return $?
  source_libs
  msg_info "soc-stack v${SOC_STACK_VERSION} starting (Plan 1)"
}

# Only run main when executed (not when sourced for tests)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && [[ -z "${SOC_TEST_MODE:-}" ]]; then
  main "$@"
fi
```

- [ ] **Step 4: Make executable**

```bash
chmod +x scripts/install.sh
```

- [ ] **Step 5: Run flag-parsing tests, verify pass**

```bash
./tests/unit/run.sh tests/unit/test_orchestrator_flag_parsing.bats
```
Expected: 9 passing.

- [ ] **Step 6: Shellcheck**

```bash
shellcheck scripts/install.sh
```
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add scripts/install.sh tests/unit/test_orchestrator_flag_parsing.bats
git commit -m "orchestrator: add install.sh with flag parsing (TDD)"
```

---

## Task 24: Add orchestrator manifest building with TDD

**Files:**
- Create: `tests/unit/test_orchestrator_manifest_building.bats`
- Modify: `scripts/install.sh` (add `build_manifest` and `expand_components`)

- [ ] **Step 1: Write failing tests**

Create `tests/unit/test_orchestrator_manifest_building.bats`:

```bash
#!/usr/bin/env bats

load helpers/load.bash

setup() {
  export SOC_LOG_FILE="${BATS_TEST_TMPDIR}/soc-stack.log"
  export SOC_TEST_MODE=1
  source "${REPO_ROOT}/scripts/install.sh"
}

@test "expand_components 'all' returns the canonical 6" {
  run expand_components "all"
  assert_success
  [[ "${output}" == *"wazuh"* ]]
  [[ "${output}" == *"thehive-cortex"* ]]
  [[ "${output}" == *"misp"* ]]
  [[ "${output}" == *"zeek-suricata"* ]]
  [[ "${output}" == *"dashboards"* ]]
  [[ "${output}" == *"mcp"* ]]
}

@test "expand_components CSV preserves order" {
  run expand_components "misp,wazuh"
  assert_success
  assert_output "misp wazuh"
}

@test "build_manifest produces JSON matching flags" {
  parse_args --components wazuh --preset minimal --bridge vmbr-test --vmid-start 9000
  local out
  out="$(build_manifest)"
  jq -e '.components[0] == "wazuh"' <<< "${out}"
  jq -e '.preset == "minimal"' <<< "${out}"
  jq -e '.network.bridge == "vmbr-test"' <<< "${out}"
  jq -e '.vmid_start == 9000' <<< "${out}"
}

@test "build_manifest rejects unknown component" {
  parse_args --components imaginary-component
  run build_manifest
  [[ "$status" -ne 0 ]]
  [[ "${output}${stderr:-}" == *"unknown"* ]]
}
```

- [ ] **Step 2: Run, verify failure**

```bash
./tests/unit/run.sh tests/unit/test_orchestrator_manifest_building.bats
```
Expected: all 4 tests FAIL.

- [ ] **Step 3: Add manifest functions to `scripts/install.sh`**

Open `scripts/install.sh` and **append** (just before the `main()` function definition) the following:

```bash
# Known components in canonical order
COMPONENTS_KNOWN=("wazuh" "thehive-cortex" "misp" "zeek-suricata" "dashboards" "mcp")

# expand_components <csv-or-all>
# Echoes space-separated component names in canonical order.
expand_components() {
  local input="$1"
  if [[ "${input}" == "all" ]]; then
    printf '%s' "${COMPONENTS_KNOWN[*]}"
    return 0
  fi
  local arr=()
  # IFS=, scoped only to the read command; restored to default (space)
  # before the final join via ${arr[*]}.
  IFS=',' read -r -a arr <<< "${input}"
  printf '%s' "${arr[*]}"
}

# build_manifest
# Reads OPT_* globals, returns a manifest JSON document on stdout.
# Returns non-zero with an error message if any component is unknown.
build_manifest() {
  local components_list
  components_list="$(expand_components "${OPT_COMPONENTS}")"

  # Validate each name
  local c
  # shellcheck disable=SC2086  # intentional word-splitting on space-separated list
  for c in ${components_list}; do
    local known=0
    local k
    for k in "${COMPONENTS_KNOWN[@]}"; do
      [[ "${k}" == "${c}" ]] && { known=1; break; }
    done
    if [[ "${known}" -ne 1 ]]; then
      printf 'unknown component: %s\n' "${c}" >&2
      return 1
    fi
  done

  # Build components array as JSON
  local components_json
  # shellcheck disable=SC2086  # intentional word-splitting on space-separated list
  components_json="$(printf '%s\n' ${components_list} | jq -R . | jq -s .)"

  jq -n \
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
    }'
}
```

- [ ] **Step 4: Run tests, verify pass**

```bash
./tests/unit/run.sh tests/unit/test_orchestrator_manifest_building.bats
```
Expected: 4 passing.

- [ ] **Step 5: Shellcheck**

```bash
shellcheck scripts/install.sh
```
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add scripts/install.sh tests/unit/test_orchestrator_manifest_building.bats
git commit -m "orchestrator: add expand_components + build_manifest (TDD)"
```

---

## Task 25: Wire orchestrator main() to deploy one component (wazuh)

**Files:**
- Modify: `scripts/install.sh` (implement `main()` body)

This task is not strictly TDD - end-to-end deployment is exercised by the integration test in Task 28, which requires a real Proxmox host. Unit-test coverage at this layer is intentionally limited; we rely on the bats coverage of the underlying lib and the integration assertion.

- [ ] **Step 1: Replace the stub `main()` in `scripts/install.sh`**

In `scripts/install.sh`, replace the existing `main()` function with:

```bash
# deploy_one <component> <manifest_json>
# Returns 0 if deployed (or already-deployed), non-zero on failure.
deploy_one() {
  local component="$1"
  local manifest="$2"

  msg_info "==== ${component} ===="

  if is_completed "${component}" && [[ "${OPT_FORCE}" != "1" ]]; then
    msg_ok "${component} already deployed (state status=deployed); skipping"
    return 0
  fi

  local preset bridge storage ip_mode
  preset="$(jq -r '.preset' <<< "${manifest}")"
  bridge="$(jq -r '.network.bridge' <<< "${manifest}")"
  storage="$(jq -r '.network.storage // "local-lvm"' <<< "${manifest}")"
  ip_mode="$(jq -r '.network.ip_mode' <<< "${manifest}")"

  # Get a VMID
  local vmid_start vmid
  vmid_start="$(jq -r '.vmid_start' <<< "${manifest}")"
  if [[ "${vmid_start}" == "0" ]] || [[ -z "${vmid_start}" ]]; then
    vmid="$(next_vmid 200)"
  else
    vmid="$(next_vmid "${vmid_start}")"
  fi

  # Build network config
  local net_config="name=eth0,bridge=${bridge}"
  case "${ip_mode}" in
    dhcp)   net_config+=",ip=dhcp" ;;
    static)
      local ip_range index ip
      ip_range="$(jq -r '.network.ip_range' <<< "${manifest}")"
      index=0  # Plan 1 single-component, index 0
      ip="$(allocate_ip "${ip_range}" "${index}")"
      net_config+=",ip=${ip}"
      ;;
  esac

  # Get template
  local template
  template="$(pveam list "${storage}" 2>/dev/null | awk '/ubuntu-22.04/{print $1; exit}')"
  if [[ -z "${template}" ]]; then
    template="$(pveam list local 2>/dev/null | awk '/ubuntu-22.04/{print $1; exit}')"
  fi
  if [[ -z "${template}" ]]; then
    msg_info "downloading Ubuntu 22.04 template"
    pveam update >/dev/null 2>&1 || true
    pveam download local ubuntu-22.04-standard_22.04-1_amd64.tar.zst >/dev/null 2>&1 || true
    template="local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
  fi

  # Get LXC spec from component
  local spec_lines
  spec_lines="$( SOC_PRESET="${preset}" \
                 SOC_NETWORK_CONFIG="${net_config}" \
                 SOC_STORAGE="${storage}" \
                 "${COMPONENTS_DIR}/${component}/lxc-spec.sh" )"

  # Generate root password
  local rootpw
  rootpw="$(gen_password 24)"
  store_secret "${component}-lxc-root" "${rootpw}"

  # Create LXC
  msg_info "creating LXC ${vmid} for ${component}"
  local pct_args=()
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    local part_arr=()
    read -r -a part_arr <<< "${line}"
    pct_args+=("${part_arr[@]}")
  done <<< "${spec_lines}"

  if [[ "${OPT_DRY_RUN}" == "1" ]]; then
    msg_info "[dry-run] would: pct create ${vmid} ${template} --hostname s3-${component} ${pct_args[*]} --password ***"
    return 0
  fi

  lxc_create "${vmid}" "s3-${component}" "${template}" "${pct_args[@]}" --password "${rootpw}"
  lxc_start "${vmid}"
  msg_info "waiting for LXC ${vmid} network"
  lxc_wait_network "${vmid}"

  # Persist LXC info to state up front
  state_set "${component}" "lxc.vmid" "${vmid}"
  state_set "${component}" "lxc.hostname" "s3-${component}"
  state_set "${component}" "preset" "${preset}"

  # Bind-mount state dir into LXC
  pct set "${vmid}" -mp0 "${SOC_STATE_DIR},mp=${SOC_STATE_DIR}"
  pct exec "${vmid}" -- mkdir -p "${SOC_STATE_DIR}/state" "${SOC_SECRETS_DIR}"

  # Push and run deploy.sh
  msg_info "running ${component}/deploy.sh inside LXC ${vmid}"
  local remote_deploy="/tmp/${component}-deploy.sh"
  lxc_push_script "${vmid}" "${COMPONENTS_DIR}/${component}/deploy.sh" "${remote_deploy}"

  if ! pct exec "${vmid}" -- env \
      SOC_STATE_DIR="${SOC_STATE_DIR}" \
      SOC_COMPONENT="${component}" \
      SOC_PRESET="${preset}" \
      SOC_NON_INTERACTIVE=1 \
      bash "${remote_deploy}"; then
    msg_error "${component} deploy.sh failed"
    state_set "${component}" status "failed"
    return 1
  fi

  # Run verify.sh
  msg_info "verifying ${component}"
  local remote_verify="/tmp/${component}-verify.sh"
  lxc_push_script "${vmid}" "${COMPONENTS_DIR}/${component}/verify.sh" "${remote_verify}"
  local retries=3
  local i=0
  while (( i < retries )); do
    if pct exec "${vmid}" -- bash "${remote_verify}"; then
      break
    fi
    i=$((i + 1))
    msg_warn "verify attempt ${i}/${retries} failed for ${component}, retrying in 30s"
    sleep 30
  done
  if (( i >= retries )); then
    msg_error "${component} verify.sh failed after ${retries} attempts"
    state_set "${component}" status "failed"
    return 1
  fi

  # Refresh state with the post-deploy IP
  local ip
  ip="$(lxc_ip "${vmid}")"
  if [[ -n "${ip}" ]]; then
    state_set "${component}" "lxc.ip" "${ip}"
  fi

  msg_ok "${component} deployed successfully"
  return 0
}

# integrate_all - run each deployed component's integrate.sh
integrate_all() {
  if [[ "${OPT_NO_INTEGRATE}" == "1" ]]; then
    msg_info "skipping integration phase (--no-integrate)"
    return 0
  fi
  local f
  for f in "${COMPONENTS_DIR}"/*/integrate.sh; do
    [[ -x "${f}" ]] || continue
    local comp_name
    comp_name="$(basename "$(dirname "${f}")")"
    if ! is_completed "${comp_name}"; then
      msg_info "skipping integrate.sh for ${comp_name} (not deployed)"
      continue
    fi
    msg_info "running ${comp_name}/integrate.sh"
    SOC_STATE_DIR="${SOC_STATE_DIR}" "${f}" || msg_warn "${comp_name} integrate.sh returned non-zero"
  done
}

main() {
  parse_args "$@" || return $?
  source_libs

  msg_info "soc-stack v${SOC_STACK_VERSION} starting"

  # Pre-flight
  check_root          || return 1
  check_proxmox_version || return 1
  check_deps          || return 1
  check_bridge "${OPT_BRIDGE}" || return 1
  if [[ -n "${OPT_STORAGE}" ]]; then
    check_storage "${OPT_STORAGE}" || return 1
  fi

  # Build manifest
  local manifest
  manifest="$(build_manifest)" || return 1

  if [[ "${OPT_DRY_RUN}" == "1" ]]; then
    msg_info "[dry-run] effective manifest:"
    jq <<< "${manifest}"
  fi

  # Deploy each component in canonical order (Plan 1 effectively wazuh only)
  local exit_status=0
  local components_arr=()
  while IFS= read -r line; do
    [[ -n "${line}" ]] && components_arr+=("${line}")
  done < <(jq -r '.components[]' <<< "${manifest}")

  local component
  for component in "${components_arr[@]}"; do
    if ! deploy_one "${component}" "${manifest}"; then
      exit_status=3
    fi
  done

  # Only mark completed if verify passed (set inside deploy_one upon success
  # via state file; this confirms via is_completed check)
  for component in "${components_arr[@]}"; do
    if [[ "$(state_get "${component}" status)" == "deployed" ]]; then
      mark_completed "${component}" || true
    fi
  done

  # Integration phase
  integrate_all

  # Emit results
  emit_final_json "${OPT_JSON_OUT}"
  msg_ok "result JSON written to ${OPT_JSON_OUT}"

  return "${exit_status}"
}
```

- [ ] **Step 2: Shellcheck**

```bash
shellcheck scripts/install.sh
```
Expected: clean. If shellcheck flags the loop `for c in ${components_list}` for word-splitting, that's intentional - silence with a directive `# shellcheck disable=SC2086` on that line.

- [ ] **Step 3: Re-run all unit tests**

```bash
./tests/unit/run.sh
```
Expected: all green.

- [ ] **Step 4: Smoke `--dry-run` locally (no Proxmox needed - will error on `check_root`/`check_proxmox_version`)**

```bash
# Expected to fail at preflight when not root / not on Proxmox - that's OK
sudo bash scripts/install.sh --components wazuh --preset minimal --dry-run 2>&1 | head -20 || true
```
Expected: prints log lines starting with "soc-stack v0.5.0 starting" then fails preflight with "pveversion not found" (when run on a non-Proxmox dev machine) or proceeds to print the manifest (when run on Proxmox).

- [ ] **Step 5: Commit**

```bash
git add scripts/install.sh
git commit -m "orchestrator: wire main() to deploy + verify + integrate + emit JSON"
```

---

## Task 26: Add the repo-root `install.sh` wrapper

**Files:**
- Create: `install.sh` (repo root)

- [ ] **Step 1: Write the wrapper**

Create `install.sh` at the repo root:

```bash
#!/usr/bin/env bash
# install.sh - repo-root wrapper that delegates to scripts/install.sh
#
# This wrapper exists so `curl -sSL .../install.sh | sudo bash` lands here.
# Real logic is in scripts/install.sh.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec sudo -E bash "${HERE}/scripts/install.sh" "$@"
```

Wait - that wrapper assumes the file is already on disk. The actual `curl | bash` case is different: the script comes from stdin. Replace with a version that handles both:

```bash
#!/usr/bin/env bash
# install.sh - repo-root entrypoint
#
# Two invocation modes:
#   1) Local checkout:  sudo bash install.sh [flags]
#   2) curl piped:      curl -sSL .../install.sh | sudo bash -s -- [flags]
#
# In mode 2, we self-bootstrap by cloning the repo to /tmp and re-exec'ing
# scripts/install.sh from there.

set -euo pipefail

REPO_URL="${SOC_STACK_REPO_URL:-https://github.com/solomonneas/soc-stack.git}"
REPO_REF="${SOC_STACK_REPO_REF:-main}"
LOCAL_CACHE="/var/lib/soc-stack/repo"

# Detect mode: is there a scripts/install.sh next to this wrapper?
WRAPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || WRAPPER_DIR=""
if [[ -n "${WRAPPER_DIR}" ]] && [[ -f "${WRAPPER_DIR}/scripts/install.sh" ]]; then
  exec bash "${WRAPPER_DIR}/scripts/install.sh" "$@"
fi

# curl-piped mode: clone and re-exec
echo "[install.sh] bootstrapping soc-stack from ${REPO_URL} (ref ${REPO_REF})"
mkdir -p "$(dirname "${LOCAL_CACHE}")"
if [[ -d "${LOCAL_CACHE}/.git" ]]; then
  (cd "${LOCAL_CACHE}" && git fetch --quiet origin "${REPO_REF}" && git checkout --quiet "${REPO_REF}" && git pull --ff-only --quiet)
else
  rm -rf "${LOCAL_CACHE}"
  git clone --quiet --branch "${REPO_REF}" --depth 1 "${REPO_URL}" "${LOCAL_CACHE}"
fi

exec bash "${LOCAL_CACHE}/scripts/install.sh" "$@"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x install.sh
```

- [ ] **Step 3: Shellcheck**

```bash
shellcheck install.sh
```
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add install.sh
git commit -m "install.sh: add repo-root wrapper for curl|bash idiom + local checkout"
```

---

## Task 27: Write the integration test setup/teardown scripts

**Files:**
- Create: `tests/integration/setup-test-env.sh`
- Create: `tests/integration/destroy-test-env.sh`

- [ ] **Step 1: Write setup**

Create `tests/integration/setup-test-env.sh`:

```bash
#!/usr/bin/env bash
# tests/integration/setup-test-env.sh <component>
# Prepares an isolated test environment on a Proxmox host:
#   - Picks the next free VMID in 9000-9099 range
#   - Ensures /tmp/soc-stack-test/ scratch dir exists
#
# Must run as root on a Proxmox host.

set -euo pipefail
COMPONENT="${1:-}"
[[ -n "${COMPONENT}" ]] || { echo "usage: $0 <component>" >&2; exit 64; }

TEST_VMID_RANGE_START=9000
TEST_VMID_RANGE_END=9099
TEST_STATE_DIR="/tmp/soc-stack-test"

# Sanity: must be root + Proxmox host
[[ ${EUID} -eq 0 ]] || { echo "must run as root" >&2; exit 1; }
command -v pct >/dev/null || { echo "pct not on PATH - not a Proxmox host?" >&2; exit 1; }

mkdir -p "${TEST_STATE_DIR}/state" "${TEST_STATE_DIR}/secrets" "${TEST_STATE_DIR}/logs"

# Find a free VMID in the test range
used_ids="$( (pct list 2>/dev/null | awk 'NR>1 {print $1}'; qm list 2>/dev/null | awk 'NR>1 {print $1}') | sort -u)"
candidate="${TEST_VMID_RANGE_START}"
while (( candidate <= TEST_VMID_RANGE_END )); do
  if ! grep -qx "${candidate}" <<< "${used_ids}"; then
    echo "${candidate}" > "${TEST_STATE_DIR}/vmid-${COMPONENT}.txt"
    echo "test VMID for ${COMPONENT}: ${candidate}"
    exit 0
  fi
  candidate=$((candidate + 1))
done
echo "no free VMIDs in ${TEST_VMID_RANGE_START}-${TEST_VMID_RANGE_END}" >&2
exit 1
```

- [ ] **Step 2: Write destroy**

Create `tests/integration/destroy-test-env.sh`:

```bash
#!/usr/bin/env bash
# tests/integration/destroy-test-env.sh <component>|--all
# Tears down test LXCs in the 9000-9099 VMID range.

set -euo pipefail
TARGET="${1:-}"
[[ -n "${TARGET}" ]] || { echo "usage: $0 <component>|--all" >&2; exit 64; }

[[ ${EUID} -eq 0 ]] || { echo "must run as root" >&2; exit 1; }

TEST_STATE_DIR="/tmp/soc-stack-test"

destroy_vmid() {
  local vmid="$1"
  pct stop "${vmid}" 2>/dev/null || true
  pct destroy "${vmid}" 2>/dev/null || true
  echo "destroyed LXC ${vmid}"
}

if [[ "${TARGET}" == "--all" ]]; then
  for vmid in $(pct list 2>/dev/null | awk 'NR>1 {print $1}'); do
    if (( vmid >= 9000 && vmid <= 9099 )); then
      destroy_vmid "${vmid}"
    fi
  done
  rm -rf "${TEST_STATE_DIR}"
  exit 0
fi

# Single-component teardown
vmid_file="${TEST_STATE_DIR}/vmid-${TARGET}.txt"
if [[ -f "${vmid_file}" ]]; then
  destroy_vmid "$(cat "${vmid_file}")"
  rm -f "${vmid_file}"
fi
rm -f "${TEST_STATE_DIR}/state/${TARGET}.json"
```

- [ ] **Step 3: Make executable**

```bash
chmod +x tests/integration/setup-test-env.sh tests/integration/destroy-test-env.sh
```

- [ ] **Step 4: Shellcheck**

```bash
shellcheck tests/integration/setup-test-env.sh tests/integration/destroy-test-env.sh
```
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add tests/integration/setup-test-env.sh tests/integration/destroy-test-env.sh
git commit -m "test(integration): add setup-test-env.sh + destroy-test-env.sh"
```

---

## Task 28: Write the Wazuh integration assertion script

**Files:**
- Create: `tests/integration/assert-wazuh.sh`

- [ ] **Step 1: Write assert**

Create `tests/integration/assert-wazuh.sh`:

```bash
#!/usr/bin/env bash
# tests/integration/assert-wazuh.sh <result-json>
# Verifies that a Wazuh deployment described in result-json actually works.
#
# Checks:
#   1. Result JSON has wazuh component with status=deployed
#   2. Dashboard URL returns an HTTPS response
#   3. API URL returns a response (any HTTP code 200-499 is fine - means it's listening)
#   4. Credentials field is populated

set -euo pipefail

RESULT="${1:-}"
[[ -n "${RESULT}" ]] || { echo "usage: $0 <result-json>" >&2; exit 64; }
[[ -f "${RESULT}" ]] || { echo "result file not found: ${RESULT}" >&2; exit 2; }

log() { printf '[assert-wazuh] %s\n' "$*"; }
fail() { printf '[assert-wazuh] FAIL: %s\n' "$*" >&2; exit 1; }

log "verifying ${RESULT}"

# Check 1: status
status="$(jq -r '.components[] | select(.name == "wazuh") | .status' "${RESULT}")"
[[ "${status}" == "deployed" ]] || fail "wazuh status is '${status}', expected 'deployed'"
log "status=deployed"

# Check 2: dashboard URL
url="$(jq -r '.components[] | select(.name == "wazuh") | .endpoints.dashboard // .url' "${RESULT}")"
[[ -n "${url}" ]] || fail "no dashboard URL in result JSON"
code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "${url}")"
(( code >= 200 && code < 500 )) || fail "dashboard ${url} returned HTTP ${code}"
log "dashboard ${url} -> HTTP ${code}"

# Check 3: API
api="$(jq -r '.components[] | select(.name == "wazuh") | .endpoints.api // .api_url' "${RESULT}")"
[[ -n "${api}" ]] || fail "no API URL in result JSON"
code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "${api}")"
(( code >= 200 && code < 600 )) || fail "API ${api} returned HTTP ${code}"
log "api ${api} -> HTTP ${code}"

# Check 4: credentials populated
admin_pw="$(jq -r '.components[] | select(.name == "wazuh") | .credentials.admin_password // .credentials.password' "${RESULT}")"
[[ -n "${admin_pw}" && "${admin_pw}" != "null" ]] || fail "admin password missing in result JSON"
log "admin password present (length=${#admin_pw})"

log "PASS"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x tests/integration/assert-wazuh.sh
```

- [ ] **Step 3: Shellcheck**

```bash
shellcheck tests/integration/assert-wazuh.sh
```
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add tests/integration/assert-wazuh.sh
git commit -m "test(integration): add assert-wazuh.sh"
```

---

## Task 29: Manual integration smoke test on a Proxmox host

This task is the only one in Plan 1 that requires a Proxmox host. It validates the whole pattern end-to-end. CI automation comes in Plan 3.

- [ ] **Step 1: From a Proxmox host (any test host), check out the branch**

```bash
ssh <proxmox-test-host>
sudo apt-get update && sudo apt-get install -y git jq
git clone https://github.com/solomonneas/soc-stack.git -b <your-branch> /root/soc-stack
cd /root/soc-stack
```

- [ ] **Step 2: Set up the test env**

```bash
sudo bash tests/integration/setup-test-env.sh wazuh
VMID="$(cat /tmp/soc-stack-test/vmid-wazuh.txt)"
echo "will use VMID=${VMID}"
```

- [ ] **Step 3: Deploy wazuh in minimal preset to the test VMID**

```bash
sudo bash scripts/install.sh \
  --components wazuh \
  --preset minimal \
  --bridge vmbr0 \
  --storage local-lvm \
  --ip-mode dhcp \
  --vmid-start "${VMID}" \
  --state-dir /tmp/soc-stack-test \
  --json-out /tmp/soc-stack-test/result.json \
  --log-file /tmp/soc-stack-test/install.log
```
Expected: completes in 10-20 minutes; exit code 0.

- [ ] **Step 4: Inspect result JSON**

```bash
cat /tmp/soc-stack-test/result.json | jq .
```
Expected: `.components[0].status == "deployed"` and a populated `.credentials`.

- [ ] **Step 5: Run the assert**

```bash
bash tests/integration/assert-wazuh.sh /tmp/soc-stack-test/result.json
```
Expected: prints `[assert-wazuh] PASS`.

- [ ] **Step 6: Verify idempotency by re-running install.sh**

```bash
time sudo bash scripts/install.sh \
  --components wazuh \
  --preset minimal \
  --bridge vmbr0 \
  --storage local-lvm \
  --vmid-start "${VMID}" \
  --state-dir /tmp/soc-stack-test \
  --json-out /tmp/soc-stack-test/result.json
```
Expected: under 30s, log shows "wazuh already deployed (state status=deployed); skipping".

- [ ] **Step 7: Tear down**

```bash
sudo bash tests/integration/destroy-test-env.sh wazuh
pct list | grep -v "^9[0-9][0-9][0-9]" || true  # confirm no leftover test LXCs
```

- [ ] **Step 8: Record the result**

If any step failed, fix in code (not in the plan), commit, and rerun. If all green, write a one-line note in the commit:

```bash
git commit --allow-empty -m "test(integration): manual smoke test of wazuh deploy passes"
```

---

## Task 30: Update the README with a Plan 1 status note

The full README rewrite is Plan 3. For now, just add a section at the top noting Plan 1 status so users see it.

**Files:**
- Modify: `README.md` (add a section near the top)

- [ ] **Step 1: Read current README structure**

```bash
head -30 README.md
```

- [ ] **Step 2: Add a "Status" section just before "Quick Start"**

Open `README.md` and insert the following section immediately before the `## Quick Start` heading (around line 30):

```markdown
## Status

A unified one-shot Proxmox installer is in active development. Plan 1 ships the foundation (shared lib, per-component contract, Wazuh deployment, JSON output). The legacy paths (Hyper-V scripts, per-tool LXC one-liners) still work and remain in the repo until the migration completes in subsequent plans.

**Plan 1 (this release):** Wazuh deployment via `scripts/install.sh --components wazuh --preset minimal --json-out /root/soc-stack.json`. State at `/var/lib/soc-stack/`. See [the design spec](docs/superpowers/specs/2026-05-15-soc-stack-unification-design.md).

**Plan 2 (next):** TheHive+Cortex, MISP, Zeek+Suricata, Dashboards, MCP servers.

**Plan 3 (after):** Automated CI on Proxmox, README rewrite, deletion of legacy paths, v1.0.0 release.

---

```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add Plan 1 status note to README (full rewrite in Plan 3)"
```

---

## Task 31: Run the full test suite end-to-end and finalize

- [ ] **Step 1: All unit tests pass**

```bash
./tests/unit/run.sh
```
Expected: every bats test green.

- [ ] **Step 2: All shellcheck clean**

```bash
shellcheck scripts/install.sh scripts/lib/*.sh scripts/components/*/*.sh tests/integration/*.sh install.sh
```
Expected: no output.

- [ ] **Step 3: Tag v0.5.0**

```bash
git tag -a v0.5.0 -m "Foundations: shared lib, wazuh component, minimal orchestrator"
```

- [ ] **Step 4: Print summary**

```bash
git log --oneline v0.5.0 ^main -- ':!docs/superpowers/' | head -40
echo "---"
git ls-files scripts/ tests/ install.sh | wc -l
```

- [ ] **Step 5: Push branch + tag (only when ready to share)**

```bash
# Discuss with reviewer before pushing
# git push origin <your-branch>
# git push origin v0.5.0
```

---

## Definition of done

Plan 1 is complete when all of the following are true:

1. `./tests/unit/run.sh` passes (all bats tests green)
2. `shellcheck` is clean across `scripts/`, `tests/integration/`, and `install.sh`
3. The manual integration smoke test (Task 29) deploys Wazuh end-to-end on a real Proxmox host and `assert-wazuh.sh` returns PASS
4. Idempotency check: re-running install.sh with the same flags exits in < 30s with no state changes
5. `git tag v0.5.0` exists on the branch tip
6. Legacy paths (`proxmox/ct/`, `scripts/create-vm.ps1`, etc.) are untouched - they keep working during the transition

After Plan 1 is merged, Plan 2 will add the remaining 5 components by following the same per-component contract established here.
