<#
.SYNOPSIS
    Cleanly removes a Hyper-V VM and its VHDX.

.PARAMETER VMName
    Name of the VM to destroy.

.PARAMETER VHDXPath
    Override VHDX storage path. Default: C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\

.PARAMETER Force
    Skip confirmation prompt.

.EXAMPLE
    .\destroy-vm.ps1 -VMName "misp"
    .\destroy-vm.ps1 -VMName "thehive-cortex" -Force
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$VMName,

    [string]$VHDXPath = "C:\ProgramData\Microsoft\Windows\Virtual Hard Disks",

    [switch]$Force
)

$ErrorActionPreference = "Stop"

$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if (-not $vm) {
    Write-Host "VM '$VMName' not found."
    exit 0
}

$vhdx = Join-Path $VHDXPath "$VMName.vhdx"

if (-not $Force) {
    Write-Host ""
    Write-Host "This will permanently destroy:"
    Write-Host "  VM:   $VMName (State: $($vm.State))"
    if (Test-Path $vhdx) {
        Write-Host "  VHDX: $vhdx"
    }
    Write-Host ""
    $confirm = Read-Host "Type 'yes' to confirm"
    if ($confirm -ne "yes") {
        Write-Host "Cancelled."
        exit 0
    }
}

# Stop if running
if ($vm.State -eq "Running") {
    Write-Host "[1/3] Stopping VM..."
    Stop-VM -Name $VMName -Force -TurnOff
    Write-Host "      Stopped."
} else {
    Write-Host "[1/3] VM already stopped."
}

# Remove VM from Hyper-V
Write-Host "[2/3] Removing VM from Hyper-V..."
Remove-VM -Name $VMName -Force
Write-Host "      Removed."

# Delete VHDX
if (Test-Path $vhdx) {
    Write-Host "[3/3] Deleting VHDX..."
    Remove-Item $vhdx -Force
    Write-Host "      Deleted: $vhdx"
} else {
    Write-Host "[3/3] No VHDX found at $vhdx (skipping)."
}

Write-Host ""
Write-Host "VM '$VMName' destroyed."
