#!/usr/bin/env bash
# scripts/components/misp/lxc-spec.sh
# Emits LXC creation flags for MISP (Docker Compose inside one LXC).
# Inputs (env):
#   SOC_PRESET           - minimal|standard|production
#   SOC_NETWORK_CONFIG   - pre-built --net0 string
#   SOC_STORAGE          - storage pool

set -euo pipefail

case "${SOC_PRESET:-standard}" in
  minimal)    RAM=2048; DISK=20; CORES=1 ;;
  standard)   RAM=4096; DISK=40; CORES=2 ;;
  production) RAM=8192; DISK=80; CORES=4 ;;
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
