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
# Polls for connectivity from inside the LXC. Default 240s timeout
# (up from 180s in v0.5.0 - on busy hosts DHCP can take > 3 minutes).
# After exhausting the primary loop, makes one final 30s grace probe with a
# longer per-attempt timeout to catch slow-DHCP-finally-completing.
# The grace probe only runs when timeout >= 60 to keep short-timeout
# unit tests fast.
lxc_wait_network() {
  local vmid="$1"
  local timeout="${2:-360}"
  local elapsed=0
  while (( elapsed < timeout )); do
    if pct exec "${vmid}" -- ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done

  # Final grace probe: 30s with a longer per-attempt timeout
  # Skip when timeout is small (unit test path) to avoid hanging tests.
  if (( timeout >= 60 )); then
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
  fi

  msg_error "network wait timed out for LXC ${vmid} after ${timeout}s + 30s grace"
  return 1
}

# lxc_ip <vmid>
# Prints the LXC's primary IP, or empty.
lxc_ip() {
  pct exec "$1" -- hostname -I 2>/dev/null | awk '{print $1}'
}

# _pick_ubuntu_from_list <storage>
# Prints the newest supported Ubuntu 22.04 standard template volume already
# present on <storage>, or returns non-zero when none is present.
_pick_ubuntu_from_list() {
  local storage="$1"
  local candidates newest
  candidates="$(pveam list "${storage}" 2>/dev/null \
    | grep -oE '[^[:space:]]*ubuntu-22\.04-standard_[^[:space:]]+\.tar\.zst' \
    | sort -uV)" || return 1
  newest="$(tail -n 1 <<< "${candidates}")"
  if [[ -n "${newest}" ]]; then
    printf '%s\n' "${newest}"
    return 0
  fi
  return 1
}

# Resolved templates per storage target (cache so deploy_one does not redo
# index refresh/download for every component).
declare -gA SOC_TEMPLATE_CACHE=()

# ensure_ubuntu_template <storage>
# Resolves a usable Ubuntu container template for <storage>.
# Order: already-present local template -> pveam update -> pick a supported
# Ubuntu 22.04 template from `pveam available` -> download ->
# verify it exists. Fails with a clear error instead of ever returning a
# nonexistent template path (issue #7). Prints the volume path on success.
ensure_ubuntu_template() {
  local storage="$1"
  local found archive avail

  if [[ -n "${SOC_TEMPLATE_CACHE[${storage}]:-}" ]]; then
    printf '%s\n' "${SOC_TEMPLATE_CACHE[${storage}]}"
    return 0
  fi

  found="$(_pick_ubuntu_from_list "${storage}")" || found=""
  if [[ -z "${found}" ]] && [[ "${storage}" != "local" ]]; then
    found="$(_pick_ubuntu_from_list local)" || found=""
  fi
  if [[ -n "${found}" ]]; then
    msg_info "using existing Ubuntu template ${found}"
    SOC_TEMPLATE_CACHE["${storage}"]="${found}"
    printf '%s\n' "${found}"
    return 0
  fi

  msg_info "no Ubuntu container template present; refreshing appliance index"
  if ! pveam update >/dev/null 2>&1; then
    msg_error "'pveam update' failed - cannot refresh available container templates; check network/Proxmox repo access and rerun"
    return 1
  fi

  avail="$(pveam available 2>/dev/null \
    | grep -oE 'ubuntu-22\.04-standard_[^[:space:]]+\.tar\.zst' \
    | sort -uV)" || avail=""
  archive="$(tail -n 1 <<< "${avail}")"
  if [[ -z "${archive}" ]]; then
    msg_error "no supported Ubuntu 22.04 standard template in 'pveam available' - cannot provision containers; check appliance repos and rerun"
    return 1
  fi

  msg_info "downloading Ubuntu template ${archive}"
  if ! pveam download local "${archive}" >/dev/null 2>&1; then
    msg_error "'pveam download local ${archive}' failed - check storage space/repo access and rerun"
    return 1
  fi

  found="local:vztmpl/${archive}"
  local local_templates
  local_templates="$(pveam list local 2>/dev/null)" || local_templates=""
  if ! grep -F "vztmpl/${archive}" >/dev/null <<< "${local_templates}"; then
    msg_error "template ${found} missing after download - aborting before deployment"
    return 1
  fi

  SOC_TEMPLATE_CACHE["${storage}"]="${found}"
  printf '%s\n' "${found}"
}
