# Disable Windows Update in the golden image.
#
# CI agents should be immutable and deterministic: no auto-updates running
# mid-pipeline (CPU/IO contention, surprise reboots, toolchain drift). Patch by
# rebuilding the image on a cadence instead. As a bonus this also avoids the
# sysprep /generalize hang at GeneralizeForImaging (wuaueng.dll), which occurs
# when the Update Orchestrator / WU services are active.
$ErrorActionPreference = 'Continue'

Write-Host "=== Disabling Windows Update ==="

# 1. Disable the update services (Start=Disabled so WaaSMedic can't revive them).
foreach ($svc in 'wuauserv','UsoSvc','WaaSMedicSvc') {
    Stop-Service -Force -Name $svc -ErrorAction SilentlyContinue
    Set-Service  -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
    Write-Host "  disabled $svc"
}

# 2. Belt-and-suspenders policy keys (block auto-update even if a trigger fires).
# Guard New-Item with Test-Path: `-Force` on an existing key errors.
function Set-Dword($path, $name, $value) {
    try {
        if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
        New-ItemProperty -Path $path -Name $name -Value $value -PropertyType DWord -Force | Out-Null
        Write-Host "  set $name=$value"
    } catch { Write-Host "  WARN: $name -> $_" }
}
$au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
Set-Dword $au 'NoAutoUpdate' 1
Set-Dword $au 'AUOptions' 1   # 1 = never check
Set-Dword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'DoNotConnectToWindowsUpdateInternetLocations' 1

Write-Host "Windows Update disabled (re-enable by rebuilding the image with the latest ISO/updates)."
