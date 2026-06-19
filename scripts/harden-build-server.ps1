# Build-server cleanup/hardening for a headless CI agent.
# These are HKLM machine settings, so they persist through sysprep /generalize.
$ErrorActionPreference = 'Stop'

Write-Host "=== Configuring build-server settings ==="

# 1. Disable the Shutdown Event Tracker — the "Why did the computer shut down
#    unexpectedly?" modal that pops on every unclean shutdown (which OpenShift /
#    KubeVirt does routinely when stopping a VM). Annoying and useless on an agent.
$rel = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Reliability'
New-Item -Path $rel -Force | Out-Null
New-ItemProperty -Path $rel -Name ShutdownReasonOn -Value 0 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $rel -Name ShutdownReasonUI -Value 0 -PropertyType DWord -Force | Out-Null
Write-Host "  Shutdown Event Tracker disabled"

# 2. Stop Server Manager from opening at logon — pointless on a build server.
$sm = 'HKLM:\SOFTWARE\Microsoft\ServerManager'
New-Item -Path $sm -Force | Out-Null
New-ItemProperty -Path $sm -Name DoNotOpenServerManagerAtLogon -Value 1 -PropertyType DWord -Force | Out-Null
# Also disable the per-machine scheduled task that launches it.
Disable-ScheduledTask -TaskPath '\Microsoft\Windows\Server Manager\' -TaskName 'ServerManager' -ErrorAction SilentlyContinue | Out-Null
Write-Host "  Server Manager auto-start at logon disabled"

Write-Host "Build-server hardening applied."
