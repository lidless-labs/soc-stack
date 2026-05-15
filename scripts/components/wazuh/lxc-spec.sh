#!/usr/bin/env bash
# scripts/components/wazuh/lxc-spec.sh
# Emits LXC creation flags for Wazuh. Stdout: space-separated `pct create` args.
# Inputs (env):
#   SOC_PRESET           - minimal|standard|production
#   SOC_NETWORK_CONFIG   - pct --net0 string already built by orchestrator
#   SOC_STORAGE          - storage pool name

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
