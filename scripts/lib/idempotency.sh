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
