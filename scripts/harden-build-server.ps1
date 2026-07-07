# Build-server cleanup/hardening for a headless CI agent.
# These are HKLM machine settings, so they persist through sysprep /generalize.
# Best-effort: a single cosmetic setting must never fail the whole build.
$ErrorActionPreference = 'Continue'

Write-Host "=== Configuring build-server settings ==="

# Create a registry key only if missing. `New-Item -Force` on an EXISTING key
# errors ("cannot delete a subkey tree...") - so guard with Test-Path.
function Ensure-Key($path) {
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
}
function Set-Dword($path, $name, $value) {
    try {
        Ensure-Key $path
        New-ItemProperty -Path $path -Name $name -Value $value -PropertyType DWord -Force | Out-Null
        Write-Host "  set $name=$value"
    } catch { Write-Host "  WARN: $name -> $_" }
}

# 1. Disable the Shutdown Event Tracker - the "Why did the computer shut down
#    unexpectedly?" modal that pops on every unclean shutdown (which OpenShift /
#    KubeVirt does routinely when stopping a VM). Annoying and useless on an agent.
Set-Dword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Reliability' 'ShutdownReasonOn' 0
Set-Dword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Reliability' 'ShutdownReasonUI' 0

# 2. Stop Server Manager from opening at logon - pointless on a build server.
Set-Dword 'HKLM:\SOFTWARE\Microsoft\ServerManager' 'DoNotOpenServerManagerAtLogon' 1
Disable-ScheduledTask -TaskPath '\Microsoft\Windows\Server Manager\' -TaskName 'ServerManager' -ErrorAction SilentlyContinue | Out-Null

# 3. Suppress the per-user first-logon privacy/diagnostic-data OOBE prompt, which
#    Server 2025 shows on first interactive sign-in despite SkipUserOOBE. Keeps
#    the deployed agent's desktop clean (no foreground prompt on boot).
Set-Dword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE' 'DisablePrivacyExperience' 1

# 4. Remove Windows Defender entirely (throwaway internal CI agents, no egress). Removing the
#    FEATURE - not just runtime-disabling it - fully unloads the AV engine so it never scans
#    build I/O (a real speedup for VS + dev-tool installs that follow). Done here in the base
#    build because the windows-restart right after this script finishes the uninstall.
Write-Host "Removing Windows Defender feature..."
try {
    $r = Uninstall-WindowsFeature -Name Windows-Defender -Remove -ErrorAction Stop
    Write-Host "  Windows-Defender uninstall requested (RestartNeeded=$($r.RestartNeeded)); completes on next reboot."
} catch { Write-Host "  WARN: Windows-Defender removal failed: $_" }

Write-Host "Build-server hardening applied."
