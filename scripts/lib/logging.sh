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
