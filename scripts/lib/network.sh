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
# Given base "198.51.100.10/24" and index 3, returns "198.51.100.13/24".
# Fails if the resulting last octet would leave the valid host range
# (255 is the /24 broadcast; larger CIDRs are still capped at the octet).
allocate_ip() {
  local base_cidr="$1"
  local index="$2"
  local base_ip="${base_cidr%/*}"
  local cidr="${base_cidr#*/}"
  local base_last="${base_ip##*.}"
  local base_prefix="${base_ip%.*}"
  local last=$((base_last + index))
  if (( last > 254 )); then
    printf 'allocate_ip: %s + index %s exceeds host range (last octet %d > 254)\n' \
      "${base_cidr}" "${index}" "${last}" >&2
    return 1
  fi
  printf '%s.%d/%s\n' "${base_prefix}" "${last}" "${cidr}"
}

# validate_bridge <name>
# Exit 0 if the bridge exists on the host; non-zero otherwise.
validate_bridge() {
  local bridge="$1"
  ip link show "${bridge}" >/dev/null 2>&1 || ip a 2>/dev/null | grep -q "^[0-9]*: ${bridge}:"
}
