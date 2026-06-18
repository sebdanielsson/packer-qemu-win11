<#
.SYNOPSIS
    Generalize the image with Sysprep so it becomes a reusable template.

.DESCRIPTION
    Resets the machine SID and machine-specific state and powers the VM off.
    On the next boot the image re-runs specialize/OOBE using the supplied
    answer file (sysprep-unattend.xml) — giving each deployed instance a unique
    hostname/SID. This is the Phase-2 step for fleet deployment on OpenShift.

    Run as the LAST step before shutdown (it powers the machine off itself).
    `/mode:vm` skips physical-hardware generalization — correct and faster for
    a VM-to-VM (Proxmox -> OpenShift/KubeVirt) golden image.
#>
param([string]$UnattendPath = 'C:\sysprep-unattend.xml')
$ErrorActionPreference = 'Stop'

$sysprep = "$env:windir\System32\Sysprep\sysprep.exe"
if (-not (Test-Path $UnattendPath)) { throw "Sysprep answer file not found: $UnattendPath" }

# Surface anything that commonly blocks generalize (e.g. half-installed AppX).
Write-Host "Running Sysprep /generalize /oobe /shutdown /mode:vm ..."
& $sysprep /generalize /oobe /shutdown /mode:vm "/unattend:$UnattendPath"
# Note: on success the VM powers off; if sysprep errors it returns non-zero and
# the VM stays up — check C:\Windows\System32\Sysprep\Panther\setuperr.log.
if ($LASTEXITCODE -ne 0) { throw "Sysprep failed ($LASTEXITCODE) — see C:\Windows\System32\Sysprep\Panther\setuperr.log" }
