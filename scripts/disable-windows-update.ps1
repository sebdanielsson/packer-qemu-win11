# Disable Windows Update in the golden image.
#
# CI agents should be immutable and deterministic: no auto-updates running
# mid-pipeline (CPU/IO contention, surprise reboots, toolchain drift). Patch by
# rebuilding the image on a cadence instead. As a bonus this also avoids the
# sysprep /generalize hang at GeneralizeForImaging (wuaueng.dll), which occurs
# when the Update Orchestrator / WU services are active.
$ErrorActionPreference = 'Stop'

Write-Host "=== Disabling Windows Update ==="

# 1. Disable the update services (Start=Disabled so WaaSMedic can't revive them).
foreach ($svc in 'wuauserv','UsoSvc','WaaSMedicSvc') {
    Stop-Service -Force -Name $svc -ErrorAction SilentlyContinue
    Set-Service  -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
    Write-Host "  disabled $svc"
}

# 2. Belt-and-suspenders policy keys (block auto-update even if a trigger fires).
$au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
New-Item -Path $au -Force | Out-Null
New-ItemProperty -Path $au -Name NoAutoUpdate     -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $au -Name AUOptions        -Value 1 -PropertyType DWord -Force | Out-Null   # 1 = never check
$wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
New-Item -Path $wu -Force | Out-Null
New-ItemProperty -Path $wu -Name DoNotConnectToWindowsUpdateInternetLocations -Value 1 -PropertyType DWord -Force | Out-Null

Write-Host "Windows Update disabled (re-enable by rebuilding the image with the latest ISO/updates)."
