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
#
# We run WITHOUT /shutdown and instead wait for the completion tag, then power off
# ourselves. Why: with /shutdown, sysprep returns control to this script (with a
# BLANK exit code) the instant the OS begins powering off, and the old fallback
# `Stop-Computer -Force` RACED it - hard-killing sysprep mid-generalize before it
# wrote Sysprep_succeeded.tag. That left a half-generalized image that fails OOBE
# on deploy (no SID reset, won't boot to a usable desktop). Waiting for the tag is
# deterministic: generalize is provably complete before we cut power.
$tag = "$env:windir\System32\Sysprep\Sysprep_succeeded.tag"
Remove-Item $tag -Force -ErrorAction SilentlyContinue
Write-Host "Running Sysprep /generalize /oobe /quiet /mode:vm (waiting for the completion tag)..."
& $sysprep /generalize /oobe /quiet /mode:vm "/unattend:$UnattendPath"
$rc = $LASTEXITCODE
# sysprep may detach and keep working after the call returns; wait up to 15 min for
# generalize to actually finish (the tag is written only on full success).
$deadline = (Get-Date).AddMinutes(15)
while (-not (Test-Path $tag) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 5 }
if (Test-Path $tag) {
    Write-Host "Sysprep generalize SUCCEEDED (Sysprep_succeeded.tag present). Powering off."
} else {
    Write-Host "WARNING: Sysprep_succeeded.tag absent after 15 min (sysprep rc=$rc); see C:\Windows\System32\Sysprep\Panther\setuperr.log. Powering off anyway to preserve the artifact (image will NOT be generalized)."
}
Start-Sleep -Seconds 3
Stop-Computer -Force
