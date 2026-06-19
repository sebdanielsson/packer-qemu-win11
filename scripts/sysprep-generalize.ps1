<#
.SYNOPSIS
    Generalize the image with Sysprep so it becomes a reusable template.

.DESCRIPTION
    Resets the machine SID and machine-specific state and powers the VM off.
    On the next boot the image re-runs specialize/OOBE using the supplied
    answer file (sysprep-unattend.xml) - giving each deployed instance a unique
    hostname/SID. This is the Phase-2 step for fleet deployment on OpenShift.

    Run as the LAST step before shutdown (it powers the machine off itself).
    `/mode:vm` skips physical-hardware generalization - correct and faster for
    a VM-to-VM (Proxmox -> OpenShift/KubeVirt) golden image.
#>
param([string]$UnattendPath = 'C:\sysprep-unattend.xml')
$ErrorActionPreference = 'Stop'

$sysprep = "$env:windir\System32\Sysprep\sysprep.exe"
if (-not (Test-Path $UnattendPath)) { throw "Sysprep answer file not found: $UnattendPath" }

# Safety net: ensure the WU/Update-Orchestrator services are stopped+disabled
# before sysprep - its GeneralizeForImaging (wuaueng.dll) step hangs forever if
# they're active. disable-windows-update.ps1 normally already did this at build
# time; this is idempotent.
Write-Host "Ensuring Windows Update services are stopped (avoids the wuaueng GeneralizeForImaging hang)..."
foreach ($svc in 'wuauserv','UsoSvc','WaaSMedicSvc','bits') {
    Stop-Service -Force -Name $svc -ErrorAction SilentlyContinue
    Set-Service  -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 3

# Clear the Windows Update datastore. sysprep's GeneralizeForImaging (wuaueng.dll)
# hangs while processing a populated SoftwareDistribution store; an empty store
# lets it complete immediately. WU is disabled, so it won't be recreated.
try {
    $sd = 'C:\Windows\SoftwareDistribution'
    if (Test-Path $sd) {
        Rename-Item -Path $sd -NewName ("SoftwareDistribution.bak_" + (Get-Date -Format 'yyyyMMddHHmmss')) -ErrorAction Stop
        Write-Host "Renamed SoftwareDistribution (cleared WU datastore)."
    }
} catch {
    Write-Host "WARNING: could not clear SoftwareDistribution: $_"
}

# /quiet is REQUIRED for non-interactive runs (packer/WinRM, session 0): without
# it, sysprep can pop a message box that blocks invisibly forever instead of
# erroring. /mode:vm skips physical-hardware generalization (VM-to-VM template).
Write-Host "Running Sysprep /generalize /oobe /shutdown /quiet /mode:vm ..."
& $sysprep /generalize /oobe /shutdown /quiet /mode:vm "/unattend:$UnattendPath"
# On success the VM powers off itself. If sysprep errored it returns non-zero and
# does NOT shut down - in that case power off anyway so packer still keeps the
# build artifact (as a non-generalized image, which verification will catch)
# rather than erroring and deleting hours of work. Check setuperr.log if so.
if ($LASTEXITCODE -ne 0) {
    Write-Host "WARNING: Sysprep returned $LASTEXITCODE (see C:\Windows\System32\Sysprep\Panther\setuperr.log). Shutting down anyway to preserve the artifact."
    Start-Sleep -Seconds 5
    Stop-Computer -Force
}
