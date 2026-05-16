#!/usr/bin/env bash
# scripts/components/misp/integrate.sh
# MISP has no outbound peer wiring. It is consumed by Suricata via rule feed
# (wired in zeek-suricata/integrate.sh) and queried by MCP servers (wired in
# mcp/integrate.sh). This stub exists for contract conformance.

set -euo pipefail
: "${SOC_STATE_DIR:?SOC_STATE_DIR must be set}"

printf '[misp-integrate] MISP is consumed by other components (suricata, mcp); no outbound wiring needed.\n'
exit 0
