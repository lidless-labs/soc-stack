#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# SOC Stack - Cloud-Init ISO Builder
# Runs on Linux (linux-host). Builds the cidata ISO that Hyper-V VMs boot from.
#
# Usage:
#   ./build-iso.sh <vm-name> <password> [ssh-pubkey-file]
#
# The ISO is saved to /tmp/<vm-name>-cidata.iso
# SCP it to hyperv-host: scp /tmp/<vm-name>-cidata.iso hyperv-host:C:/Users/user/Downloads/
# ------------------------------------------------------------------------------

set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <vm-name> <password> [ssh-pubkey-file]"
    echo ""
    echo "Example:"
    echo "  $0 thehive-cortex 'MyPassword123!' ~/.ssh/id_ed25519.pub"
    exit 1
fi

VM_NAME="$1"
PASSWORD="$2"
SSH_KEY_FILE="${3:-$HOME/.ssh/id_ed25519.pub}"

WORK_DIR="/tmp/${VM_NAME}-cidata"
ISO_PATH="/tmp/${VM_NAME}-cidata.iso"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check dependencies
if ! command -v genisoimage &>/dev/null; then
    echo "[!] genisoimage not found. Install it:"
    echo "    sudo apt-get install -y genisoimage"
    exit 1
fi

# Generate password hash
echo "[*] Generating password hash..."
PASS_HASH=$(python3 -c "import crypt; print(crypt.crypt('${PASSWORD}', crypt.mksalt(crypt.METHOD_SHA512)))")

# Read SSH public key
SSH_KEY=""
if [[ -f "$SSH_KEY_FILE" ]]; then
    SSH_KEY=$(cat "$SSH_KEY_FILE")
    echo "[*] Using SSH key from $SSH_KEY_FILE"
else
    echo "[!] SSH key file not found: $SSH_KEY_FILE"
    echo "    VM will only be accessible via password."
fi

# Create working directory
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

# Build user-data
echo "[*] Building user-data..."
sed \
    -e "s|<VM_NAME>|${VM_NAME}|g" \
    -e "s|<PASSWORD_HASH>|${PASS_HASH}|g" \
    -e "s|<SSH_PUBLIC_KEY>|${SSH_KEY}|g" \
    "${SCRIPT_DIR}/base-user-data.yaml" > "${WORK_DIR}/user-data"

# If no SSH key, remove the ssh_authorized_keys lines
if [[ -z "$SSH_KEY" ]]; then
    sed -i '/ssh_authorized_keys/,/^[^ ]/{ /ssh_authorized_keys/d; /^ *- /d; }' "${WORK_DIR}/user-data"
fi

# Build meta-data
echo "[*] Building meta-data..."
sed \
    -e "s|<VM_NAME>|${VM_NAME}|g" \
    "${SCRIPT_DIR}/base-meta-data.yaml" > "${WORK_DIR}/meta-data"

# Copy network-config (no substitution needed)
echo "[*] Copying network-config..."
cp "${SCRIPT_DIR}/base-network-config.yaml" "${WORK_DIR}/network-config"

# Build ISO
echo "[*] Building ISO..."
genisoimage \
    -output "$ISO_PATH" \
    -volid cidata \
    -joliet \
    -rock \
    "${WORK_DIR}/user-data" \
    "${WORK_DIR}/meta-data" \
    "${WORK_DIR}/network-config"

# Cleanup
rm -rf "$WORK_DIR"

echo ""
echo "================================================================"
echo "  Cloud-init ISO created: $ISO_PATH"
echo ""
echo "  SCP to hyperv-host:"
echo "    scp $ISO_PATH hyperv-host:C:/Users/user/Downloads/"
echo ""
echo "  Then create the VM:"
echo "    .\\create-vm.ps1 -VMName '$VM_NAME' -CloudInitISO 'C:\\Users\\user\\Downloads\\${VM_NAME}-cidata.iso'"
echo "================================================================"
