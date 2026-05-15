#!/usr/bin/env bash
# scripts/lib/preflight.sh - environment readiness checks
# Requires: lib/logging.sh, lib/network.sh sourced first

check_root() {
  local effective_uid="${_SOC_EUID:-${EUID}}"
  if [[ ${effective_uid} -ne 0 ]]; then
    msg_error "must run as root (got EUID=${effective_uid})"
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

# bootstrap_deps
# Installs missing required deps (jq curl wget openssl) via apt-get.
# Idempotent: no-op if all are present.
# Returns 0 on success, non-zero if any install fails.
bootstrap_deps() {
  local deps=(jq curl wget openssl)
  local missing=()
  local dep
  for dep in "${deps[@]}"; do
    command -v "${dep}" >/dev/null 2>&1 || missing+=("${dep}")
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    return 0
  fi

  msg_info "installing missing deps: ${missing[*]}"
  if ! apt-get update -qq >/dev/null 2>&1; then
    msg_error "apt-get update failed"
    return 1
  fi
  if ! apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1; then
    msg_error "apt-get install failed for: ${missing[*]}"
    return 1
  fi
  msg_ok "installed: ${missing[*]}"
}
