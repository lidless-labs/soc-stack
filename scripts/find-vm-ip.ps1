<#
.SYNOPSIS
    Finds a Hyper-V VM's IP address by matching its MAC in the ARP table.

.DESCRIPTION
    Hyper-V can't report guest IPs without linux-tools-virtual installed
    in the guest. This script gets the VM's MAC address and scans the
    ARP table for a match. All Hyper-V MACs start with 00-15-5d.

.PARAMETER VMName
    Name of the VM. If omitted, lists all Hyper-V MACs and their ARP matches.

.EXAMPLE
    .\find-vm-ip.ps1 -VMName "misp"
    .\find-vm-ip.ps1   # list all Hyper-V VMs and IPs
#>

param(
    [string]$VMName
)

function Get-ArpEntries {
    $entries = @{}
    arp -a | ForEach-Object {
        if ($_ -match '^\s+([\d\.]+)\s+([\w-]+)') {
            $ip  = $Matches[1]
            $mac = $Matches[2].ToUpper()
            $entries[$mac] = $ip
        }
    }
    return $entries
}

$arpTable = Get-ArpEntries

if ($VMName) {
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Error "VM '$VMName' not found."
        exit 1
    }

    $rawMac = (Get-VMNetworkAdapter -VMName $VMName).MacAddress
    # Format: 00155D38010A -> 00-15-5D-38-01-0A
    $formatted = ($rawMac -replace '(.{2})', '$1-').TrimEnd('-').ToUpper()

    Write-Host "VM:  $VMName"
    Write-Host "MAC: $formatted"

    if ($arpTable.ContainsKey($formatted)) {
        Write-Host "IP:  $($arpTable[$formatted])"
    } else {
        Write-Host "IP:  Not found in ARP table."
        Write-Host ""
        Write-Host "The VM may still be booting. Wait 1-2 minutes and retry."
        Write-Host "Or scan from Linux: arp -a | grep '00-15-5d'"
    }
} else {
    Write-Host "All Hyper-V VMs:"
    Write-Host ""

    Get-VM | ForEach-Object {
        $name = $_.Name
        $state = $_.State
        $rawMac = (Get-VMNetworkAdapter -VMName $name).MacAddress
        $formatted = ($rawMac -replace '(.{2})', '$1-').TrimEnd('-').ToUpper()

        $ip = "Not in ARP table"
        if ($arpTable.ContainsKey($formatted)) {
            $ip = $arpTable[$formatted]
        }

        Write-Host "  $name"
        Write-Host "    State: $state"
        Write-Host "    MAC:   $formatted"
        Write-Host "    IP:    $ip"
        Write-Host ""
    }
}
