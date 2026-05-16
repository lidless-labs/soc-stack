#!/usr/bin/env bash
# scripts/components/thehive-cortex/lxc-spec.sh
# Emits LXC creation flags for TheHive + Cortex (Docker Compose inside one LXC).
# Inputs (env):
#   SOC_PRESET           - minimal|standard|production
#   SOC_NETWORK_CONFIG   - pre-built --net0 string
#   SOC_STORAGE          - storage pool

set -euo pipefail

case "${SOC_PRESET:-standard}" in
  minimal)    RAM=4096; DISK=30; CORES=2 ;;
  standard)   RAM=6144; DISK=50; CORES=2 ;;
  production) RAM=12288; DISK=80; CORES=4 ;;
  *) echo "unknown preset: ${SOC_PRESET}" >&2; exit 1 ;;
esac

cat <<EOF
--memory ${RAM}
--cores ${CORES}
--rootfs ${SOC_STORAGE:-local-lvm}:${DISK}
--net0 ${SOC_NETWORK_CONFIG:-name=eth0,bridge=vmbr0,ip=dhcp}
--unprivileged 1
--features nesting=1,keyctl=1
--onboot 1
--start 0
EOF
