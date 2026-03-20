# Hyper-V VM Automation - Cloud Images and Security Tools

## Overview
Process for creating Hyper-V Gen2 VMs from Ubuntu cloud images with cloud-init, deploying Docker-based security tools. Developed while standing up a MISP threat intelligence platform on 2026-03-20.

## Architecture
```
hyperv-host (Windows 11, Hyper-V host)
├── Downloads/ - staging area for images and ISOs
├── ProgramData/Microsoft/Windows/Virtual Hard Disks/ - VHDX storage
└── Hyper-V Manager - VM lifecycle

linux-host (Ubuntu, utility server)
├── /tmp/ - cloud image cache, ISO builds
└── genisoimage - cloud-init ISO generation
```

## The Full Workflow

### 1. Acquire the Cloud Image
Ubuntu provides qcow2 cloud images at `https://cloud-images.ubuntu.com/`. Download to linux-host (Linux box) since it has better tooling for image manipulation.

```bash
# On linux-host
wget https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img -O /tmp/ubuntu-24.04-cloud.img
```

Then SCP to hyperv-host:
```bash
# On hyperv-host
scp linux-host:/tmp/ubuntu-24.04-cloud.img C:/Users/user/Downloads/ubuntu-24.04-cloud.img
```

### 2. Install qemu-img on Windows
Needed to convert qcow2 to VHDX. Install via Chocolatey (elevated):
```powershell
choco install qemu -y
```
Binary lands at `C:\Program Files\qemu\qemu-img.exe`.

### 3. Convert qcow2 to VHDX
```powershell
& "C:\Program Files\qemu\qemu-img.exe" convert -f qcow2 -O vhdx -o subformat=dynamic "C:\Users\user\Downloads\ubuntu-24.04-cloud.img" "C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\<vm-name>.vhdx"
```

### 4. Fix the Sparse Flag (CRITICAL)
qemu-img creates VHDX files with the NTFS sparse attribute. Hyper-V refuses to start VMs from sparse VHDX files with error `0xC03A001A`.

**This MUST be done BEFORE Resize-VHD** or the resize will also fail with the same error.

```powershell
fsutil sparse setflag "C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\<vm-name>.vhdx" 0
```

### 5. Resize the VHDX
Cloud images are tiny (~630MB). Resize to your target disk size:
```powershell
Resize-VHD -Path "C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\<vm-name>.vhdx" -SizeBytes 40GB
```

### 6. Set Permissions
Hyper-V VMs run under a special service account that needs explicit file access:
```powershell
icacls "C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\<vm-name>.vhdx" /grant "NT VIRTUAL MACHINE\Virtual Machines:(F)"
```

### 7. Build Cloud-Init ISO
Cloud-init configures the VM on first boot (hostname, users, SSH keys, packages). The config is delivered via a CD-ROM ISO with volume label `cidata`.

**Files needed:**

`user-data` - main config:
```yaml
#cloud-config
hostname: <vm-name>
manage_etc_hosts: true

users:
  - name: admin
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    passwd: <sha512-hash>  # Generate with: python3 -c "import crypt; print(crypt.crypt('password', crypt.mksalt(crypt.METHOD_SHA512)))"
    ssh_authorized_keys:
      - ssh-ed25519 AAAA... your-key-here

packages:
  - docker.io
  - curl
  - git
  - htop

runcmd:
  - systemctl enable docker
  - systemctl start docker
  - usermod -aG docker admin
  - mkdir -p /usr/local/lib/docker/cli-plugins
  - curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" -o /usr/local/lib/docker/cli-plugins/docker-compose
  - chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

ssh_pwauth: true
```

`meta-data`:
```yaml
instance-id: <vm-name>-001
local-hostname: <vm-name>
```

`network-config` - ESSENTIAL for Hyper-V:
```yaml
version: 2
ethernets:
  id0:
    match:
      driver: hv_netvsc
    dhcp4: true
    dhcp6: false
```

**Build the ISO on Linux** (genisoimage not available on Windows):
```bash
genisoimage -output /tmp/<vm-name>-cidata.iso -volid cidata -joliet -rock /tmp/<vm-name>-cidata/user-data /tmp/<vm-name>-cidata/meta-data /tmp/<vm-name>-cidata/network-config
```

Then SCP back to hyperv-host.

### 8. Create and Configure the VM (Elevated PowerShell)
Run each command one at a time - batching Hyper-V commands causes intermittent failures:

```powershell
New-VM -Name "<vm-name>" -MemoryStartupBytes 4GB -Generation 2 -VHDPath "C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\<vm-name>.vhdx" -SwitchName "DNS-NIC-Switch"

Set-VMProcessor -VMName "<vm-name>" -Count 2

Set-VMFirmware -VMName "<vm-name>" -EnableSecureBoot Off

Set-VM -VMName "<vm-name>" -AutomaticCheckpointsEnabled $false -AutomaticStartAction Nothing

Add-VMDvdDrive -VMName "<vm-name>" -Path "C:\Users\user\Downloads\<vm-name>-cidata.iso"

Start-VM -Name "<vm-name>"
```

**Key settings:**
- **Generation 2** - required for UEFI boot from cloud images
- **SecureBoot Off** - Ubuntu cloud images aren't signed for Hyper-V Secure Boot
- **AutomaticCheckpoints Off** - prevents disk bloat from auto-checkpoints
- **DVD Drive** - cloud-init reads config from this ISO on first boot

### 9. Find the VM's IP Address
Hyper-V can't report guest IPs without linux-tools-virtual (guest integration services). Use ARP scan instead:

```bash
# All Hyper-V VMs have MACs starting with 00-15-5d
arp -a | grep "00-15-5d"
```

To find which IP belongs to which VM, check the VM's MAC:
```powershell
# Elevated
(Get-VMNetworkAdapter -VMName "<vm-name>").MacAddress
```

Then match the MAC in the ARP table. Format difference: PowerShell shows `00155D38010A`, ARP shows `00-15-5d-38-01-0a`.

### 10. SSH In and Verify
```bash
ssh admin@<ip>
docker --version
docker compose version
cloud-init status  # should say "done"
```

---

## Gotchas and Lessons Learned

### VHDX Sparse File Attribute (Showstopper)
**Symptom:** `Start-VM` or `Resize-VHD` fails with error `0xC03A001A: Virtual hard disk files must be uncompressed and unencrypted and must not be sparse.`

**Cause:** `qemu-img convert` creates files with the NTFS sparse attribute by default.

**Fix:** Remove sparse flag BEFORE any Hyper-V operations:
```powershell
fsutil sparse setflag "<path>.vhdx" 0
```

**Order matters:** sparse removal -> resize -> permissions -> create VM

### Cloud-Init Network Config for Hyper-V
**Symptom:** VM boots but never gets an IP address. No network at all.

**Cause:** Ubuntu cloud images don't auto-configure networking on Hyper-V. The NIC uses the `hv_netvsc` driver and may appear as `eth0` or other names depending on the image version.

**Fix:** Include a `network-config` file in the cloud-init ISO that matches by driver:
```yaml
version: 2
ethernets:
  id0:
    match:
      driver: hv_netvsc
    dhcp4: true
```

Using `match: driver: hv_netvsc` is more reliable than hardcoding `eth0`.

### Hyper-V Guest IP Reporting
**Symptom:** `(Get-VMNetworkAdapter <vm>).IPAddresses` returns empty even though the VM has an IP.

**Cause:** Hyper-V relies on guest integration services (hv_kvp_daemon) to report IP addresses. Cloud images don't have `linux-tools-virtual` / `hyperv-daemons` installed.

**Fix options:**
1. Add `linux-tools-virtual` or `hyperv-daemons` to cloud-init packages (preferred for automation)
2. Use ARP scan as fallback: `arp -a | grep "00-15-5d"`

### MariaDB OOM on Small VMs
**Symptom:** MariaDB container keeps restarting with `Out of memory (Needed 2587885448 bytes)`.

**Cause:** Default InnoDB buffer pool is 2GB which doesn't fit in 4GB RAM alongside the OS and other containers.

**Fix:** Set `INNODB_BUFFER_POOL_SIZE=512M` in `.env` for 4GB VMs. Scale proportionally:
- 4GB VM: 512M
- 8GB VM: 2048M (default)
- 16GB VM: 4096M

Also `docker compose down -v` to wipe the failed DB volume before restarting.

### Cloud-Init Only Runs Once
If cloud-init finishes (even with errors), it won't re-run on reboot. To retry:
1. Delete the VM
2. Delete the VHDX
3. Reconvert from the original cloud image
4. Rebuild from scratch

There's no "redo cloud-init" shortcut.

### Elevated PowerShell Required for Everything
All Hyper-V commands and `fsutil` need admin elevation. For automation, write scripts to `.ps1` files and run them elevated:
```powershell
Start-Process powershell -Verb RunAs -ArgumentList '-ExecutionPolicy Bypass -File C:\path\to\script.ps1' -Wait
```

For capturing output from elevated scripts, write to a file inside the script rather than trying to capture stdout.

### Don't Batch Hyper-V PowerShell Commands
Running multiple Hyper-V cmdlets in rapid succession (especially piped or in a single block) can cause intermittent failures. Run them one at a time with error checking between each.

---

## Automation Template

Reusable PowerShell script structure for creating VMs:

```powershell
param(
    [string]$VMName,
    [string]$CloudImage = "C:\Users\user\Downloads\ubuntu-24.04-cloud.img",
    [string]$CloudInitISO,
    [int64]$DiskSizeGB = 40,
    [int64]$MemoryGB = 4,
    [int]$CPUCount = 2,
    [string]$Switch = "DNS-NIC-Switch"
)

$ErrorActionPreference = "Stop"
$vhdxPath = "C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\$VMName.vhdx"

# Convert
& "C:\Program Files\qemu\qemu-img.exe" convert -f qcow2 -O vhdx -o subformat=dynamic $CloudImage $vhdxPath

# Fix sparse (BEFORE resize)
fsutil sparse setflag $vhdxPath 0

# Resize
Resize-VHD -Path $vhdxPath -SizeBytes ($DiskSizeGB * 1GB)

# Permissions
icacls $vhdxPath /grant "NT VIRTUAL MACHINE\Virtual Machines:(F)"

# Create VM
New-VM -Name $VMName -MemoryStartupBytes ($MemoryGB * 1GB) -Generation 2 -VHDPath $vhdxPath -SwitchName $Switch | Out-Null
Set-VMProcessor -VMName $VMName -Count $CPUCount
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off
Set-VM -VMName $VMName -AutomaticCheckpointsEnabled $false -AutomaticStartAction Nothing

# Attach cloud-init
Add-VMDvdDrive -VMName $VMName -Path $CloudInitISO

# Start
Start-VM -Name $VMName
Write-Host "$VMName started. Check ARP table in ~2 minutes for IP."
```

---

## Security Tool Deployment Reference

### MISP (Threat Intelligence Platform)
- **Deployed:** 2026-03-20 on `misp` VM (<VM_IP>)
- **Method:** Official misp-docker project
- **Key config:** `INNODB_BUFFER_POOL_SIZE=512M` for 4GB VMs
- **Admin:** admin@misp.local / (set during setup)
- **API Key:** (generated by setup.sh)
- **Gotcha:** Advanced authkeys enabled by default - use `cake user change_authkey` to generate keys

### Future Candidates
- **TheHive** - Incident response (already have cortex-thehive VM)
- **Wazuh** - SIEM/XDR (needs 8GB+ RAM)
- **OpenCTI** - Threat intelligence (integrates with MISP)
- **Velociraptor** - Endpoint forensics
- **Graylog** - Log management
- **Security Onion** - Network security monitoring

---

## Quick Reference Commands

```powershell
# Check VM status (elevated)
Get-VM -Name "<vm>" | Format-List Name, State, Uptime

# Get VM MAC
(Get-VMNetworkAdapter -VMName "<vm>").MacAddress

# Stop/Start
Stop-VM -Name "<vm>" -Force
Start-VM -Name "<vm>"

# Delete VM completely
Stop-VM -Name "<vm>" -Force -TurnOff
Remove-VM -Name "<vm>" -Force
Remove-Item "C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\<vm>.vhdx" -Force
```

```bash
# Find Hyper-V VM IPs via ARP
arp -a | grep "00-15-5d"

# SSH password hash generation
python3 -c "import crypt; print(crypt.crypt('yourpassword', crypt.mksalt(crypt.METHOD_SHA512)))"

# Build cloud-init ISO
genisoimage -output /tmp/cidata.iso -volid cidata -joliet -rock user-data meta-data network-config
```

---

**Tags:** #homelab #hyper-v #automation #security #powershell #cloud-init #docker
