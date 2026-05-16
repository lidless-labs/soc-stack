#!/usr/bin/env bash
# scripts/components/dashboards/lxc-spec.sh
# Emits LXC creation flags for the shared Dashboards LXC (Bro Hunter + Playbook Forge).
# Inputs (env):
#   SOC_PRESET           - minimal|standard|production
#   SOC_NETWORK_CONFIG   - pre-built --net0 string
#   SOC_STORAGE          - storage pool

set -euo pipefail

case "${SOC_PRESET:-standard}" in
  minimal)    RAM=1024; DISK=10; CORES=1 ;;
  standard)   RAM=2048; DISK=15; CORES=2 ;;
  production) RAM=4096; DISK=20; CORES=2 ;;
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
