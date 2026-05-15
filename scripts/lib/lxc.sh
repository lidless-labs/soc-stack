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
  local timeout="${2:-180}"
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
