<#
.SYNOPSIS
    Creates a Hyper-V Gen2 VM from an Ubuntu cloud image with cloud-init.

.DESCRIPTION
    Converts a qcow2 cloud image to VHDX, configures it for Hyper-V, attaches
    a cloud-init ISO, and starts the VM. Handles the sparse flag, resize, and
    permissions automatically.

    Requires: elevated PowerShell, qemu-img (choco install qemu -y)

.PARAMETER VMName
    Name for the VM and hostname.

.PARAMETER SpecFile
    Path to a JSON spec file (from specs/). Overrides RAM/CPU/Disk defaults.

.PARAMETER CloudImage
    Path to the Ubuntu cloud qcow2 image.

.PARAMETER CloudInitISO
    Path to the cloud-init ISO (built by cloud-init/build-iso.sh).

.PARAMETER DiskSizeGB
    VHDX disk size in GB. Default: 40.

.PARAMETER MemoryGB
    Startup memory in GB. Default: 4.

.PARAMETER CPUCount
    Virtual processor count. Default: 2.

.PARAMETER Switch
    Hyper-V virtual switch name. Default: DNS-NIC-Switch.

.PARAMETER VHDXPath
    Override VHDX storage path. Default: C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\

.EXAMPLE
    .\create-vm.ps1 -VMName "thehive-cortex" -CloudInitISO "C:\Users\<USERNAME>\Downloads\thehive-cortex-cidata.iso"

.EXAMPLE
    .\create-vm.ps1 -VMName "misp" -SpecFile ".\specs\misp.json" -CloudInitISO "C:\Users\<USERNAME>\Downloads\misp-cidata.iso"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$VMName,

    [string]$SpecFile,

    [string]$CloudImage = "C:\Users\<USERNAME>\Downloads\ubuntu-24.04-cloud.img",

    [Parameter(Mandatory = $true)]
    [string]$CloudInitISO,

    [int64]$DiskSizeGB = 40,
    [int64]$MemoryGB = 4,
    [int]$CPUCount = 2,
    [string]$Switch = "DNS-NIC-Switch",
    [string]$VHDXPath = "C:\ProgramData\Microsoft\Windows\Virtual Hard Disks"
)

$ErrorActionPreference = "Stop"

# ── Load spec file if provided ────────────────────────────────────────────────
if ($SpecFile -and (Test-Path $SpecFile)) {
    Write-Host "[*] Loading spec from $SpecFile"
    $spec = Get-Content $SpecFile | ConvertFrom-Json

    if ($spec.vm.cores)  { $CPUCount   = $spec.vm.cores }
    if ($spec.vm.ram_gb) { $MemoryGB   = $spec.vm.ram_gb }
    if ($spec.vm.disk_gb){ $DiskSizeGB = $spec.vm.disk_gb }
    if ($spec.vm.switch) { $Switch     = $spec.vm.switch }
    if (-not $VMName -and $spec.vm.name) { $VMName = $spec.vm.name }
}

# ── Validate ──────────────────────────────────────────────────────────────────
$qemuImg = "C:\Program Files\qemu\qemu-img.exe"
if (-not (Test-Path $qemuImg)) {
    Write-Error "qemu-img not found at $qemuImg. Install with: choco install qemu -y"
    exit 1
}

if (-not (Test-Path $CloudImage)) {
    Write-Error "Cloud image not found: $CloudImage"
    exit 1
}

if (-not (Test-Path $CloudInitISO)) {
    Write-Error "Cloud-init ISO not found: $CloudInitISO"
    exit 1
}

$vhdx = Join-Path $VHDXPath "$VMName.vhdx"

if (Test-Path $vhdx) {
    Write-Error "VHDX already exists: $vhdx. Delete it first or use destroy-vm.ps1."
    exit 1
}

if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
    Write-Error "VM '$VMName' already exists. Use destroy-vm.ps1 first."
    exit 1
}

# ── Step 1: Convert qcow2 to VHDX ────────────────────────────────────────────
Write-Host "[1/6] Converting cloud image to VHDX..."
& $qemuImg convert -f qcow2 -O vhdx -o subformat=dynamic $CloudImage $vhdx
if ($LASTEXITCODE -ne 0) {
    Write-Error "qemu-img convert failed"
    exit 1
}
Write-Host "      Created: $vhdx"

# ── Step 2: Remove sparse flag (CRITICAL - must be before Resize-VHD) ────────
Write-Host "[2/6] Removing NTFS sparse flag..."
fsutil sparse setflag $vhdx 0
Write-Host "      Sparse flag cleared"

# ── Step 3: Resize VHDX ──────────────────────────────────────────────────────
Write-Host "[3/6] Resizing VHDX to ${DiskSizeGB}GB..."
Resize-VHD -Path $vhdx -SizeBytes ($DiskSizeGB * 1GB)
Write-Host "      Resized to ${DiskSizeGB}GB"

# ── Step 4: Set permissions ───────────────────────────────────────────────────
Write-Host "[4/6] Setting Hyper-V permissions..."
icacls $vhdx /grant "NT VIRTUAL MACHINE\Virtual Machines:(F)" | Out-Null
Write-Host "      Permissions granted"

# ── Step 5: Create and configure VM ───────────────────────────────────────────
Write-Host "[5/6] Creating VM '$VMName'..."

New-VM -Name $VMName `
    -MemoryStartupBytes ($MemoryGB * 1GB) `
    -Generation 2 `
    -VHDPath $vhdx `
    -SwitchName $Switch | Out-Null

Write-Host "      Setting $CPUCount vCPUs..."
Set-VMProcessor -VMName $VMName -Count $CPUCount

Write-Host "      Disabling Secure Boot (required for Ubuntu cloud images)..."
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off

Write-Host "      Disabling automatic checkpoints..."
Set-VM -VMName $VMName -AutomaticCheckpointsEnabled $false -AutomaticStartAction Nothing

Write-Host "      Attaching cloud-init ISO..."
Add-VMDvdDrive -VMName $VMName -Path $CloudInitISO

# ── Step 6: Start VM ─────────────────────────────────────────────────────────
Write-Host "[6/6] Starting VM..."
Start-VM -Name $VMName

$mac = (Get-VMNetworkAdapter -VMName $VMName).MacAddress
$macFormatted = ($mac -replace '(.{2})', '$1-').TrimEnd('-').ToLower()

Write-Host ""
Write-Host "================================================================"
Write-Host "  VM '$VMName' created and started!"
Write-Host ""
Write-Host "  MAC Address: $macFormatted"
Write-Host "  vCPUs:       $CPUCount"
Write-Host "  RAM:         ${MemoryGB}GB"
Write-Host "  Disk:        ${DiskSizeGB}GB"
Write-Host "  Switch:      $Switch"
Write-Host ""
Write-Host "  Find the IP in ~2 minutes:"
Write-Host "    arp -a | findstr $($macFormatted.Substring(0,8))"
Write-Host ""
Write-Host "  Or from Linux:"
Write-Host "    arp -a | grep '00-15-5d'"
Write-Host ""
Write-Host "  SSH in:"
Write-Host "    ssh admin@<ip>"
Write-Host "================================================================"
