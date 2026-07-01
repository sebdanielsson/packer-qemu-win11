# Install cloudbase-init (the Windows equivalent of cloud-init) into the golden
# image so deployed VMs configure themselves at first boot from a KubeVirt
# `cloudInitConfigDrive` (OpenShift) or Proxmox cloud-init drive - e.g. apply the
# corporate proxy/CA and enroll as an Azure Pipelines agent or GitHub runner via
# user_data, with no manual RDP/VNC step.
#
# Deliberately minimal: it runs ONLY the localscripts + userdata plugins, so it
# does NOT set hostname / create users / reset passwords - the baked OOBE answer
# file (sysprep-unattend.xml) stays the single owner of per-VM identity. Runs as an
# auto-start LocalSystem service that survives sysprep /generalize.
#
# Run at BUILD time, before sysprep-generalize.ps1.
$ErrorActionPreference = 'Stop'

# Bump $Version + $Sha256 together. Releases:
#   https://github.com/cloudbase/cloudbase-init/releases
$Version = '1.1.8'
$Sha256  = '0E7FA42E0CBC0CE7657F85730B0C6CC7AFC4087A3639DF0FF51A721A0BE19BD5'
$Url     = "https://github.com/cloudbase/cloudbase-init/releases/download/$Version/CloudbaseInitSetup_$($Version -replace '\.','_')_x64.msi"

$Msi = "$env:TEMP\CloudbaseInitSetup_$($Version)_x64.msi"
$InstallDir = 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init'

Write-Host "=== Installing cloudbase-init $Version ==="
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ok = $false
for ($i = 1; $i -le 4; $i++) {
    try {
        & curl.exe -L -f --connect-timeout 30 --max-time 900 --speed-limit 10240 --speed-time 60 -o $Msi $Url
        if ($LASTEXITCODE -ne 0) { throw "curl failed with exit code $LASTEXITCODE" }
        if ((Get-Item $Msi).Length -lt 1MB) { throw "download too small ($((Get-Item $Msi).Length) bytes) - partial/blocked" }
        $ok = $true; break
    } catch {
        Write-Host "  download attempt $i/4 failed: $_"
        Start-Sleep -Seconds (10 * $i)
    }
}
if (-not $ok) { throw "failed to download cloudbase-init after 4 attempts: $Url" }

$actual = (Get-FileHash -Algorithm SHA256 -Path $Msi).Hash
if ($actual -ne $Sha256) { throw "SHA256 mismatch: expected $Sha256, got $actual" }
Write-Host "Checksum OK. Installing (silent, service as LocalSystem)..."

# RUN_SERVICE_AS_LOCAL_SYSTEM=1 so the service can import certs / set machine env /
# enroll services. Skip the MSI's own sysprep step (we run our own generalize).
$log = "$env:TEMP\cloudbase-init-msi.log"
$p = Start-Process -FilePath 'msiexec.exe' -Wait -PassThru -ArgumentList @(
    '/i', "`"$Msi`"", '/qn', '/norestart', '/l*v', "`"$log`"",
    'RUN_SERVICE_AS_LOCAL_SYSTEM=1'
)
if ($p.ExitCode -notin 0, 3010) { throw "cloudbase-init MSI failed with exit code $($p.ExitCode) (see $log)" }

# Overwrite the main conf with a minimal, OOBE-friendly config:
#  - ConfigDrive metadata service (what KubeVirt cloudInitConfigDrive presents)
#  - only localscripts + userdata plugins (no hostname/user/password plugins)
$confDir = Join-Path $InstallDir 'conf'
New-Item -ItemType Directory -Force -Path $confDir, (Join-Path $InstallDir 'log'), (Join-Path $InstallDir 'LocalScripts') | Out-Null
# KubeVirt's cloudInitConfigDrive is an ISO9660 volume on an HDD; cloudbase-init
# needs bsdtar (bundled in the MSI's bin dir) to extract it. Use the new
# [config_drive] group (types/locations) - the old config_drive_* keys in [DEFAULT]
# are deprecated - and iso only (vfat would demand mtools_path we don't ship).
$bsdtar = Join-Path $InstallDir 'bin\bsdtar.exe'
$conf = @"
[DEFAULT]
metadata_services=cloudbaseinit.metadata.services.configdrive.ConfigDriveService
bsdtar_path=$bsdtar
plugins=cloudbaseinit.plugins.common.localscripts.LocalScriptsPlugin,cloudbaseinit.plugins.common.userdata.UserDataPlugin
allow_reboot=false
stop_service_on_exit=false
check_latest_version=false
local_scripts_path=$InstallDir\LocalScripts\
logdir=$InstallDir\log\
logfile=cloudbase-init.log
default_log_levels=comtypes=INFO,suds=INFO,iso8601=WARN,requests=WARN

[config_drive]
types=iso
locations=hdd,cdrom
"@
Set-Content -Path (Join-Path $confDir 'cloudbase-init.conf') -Value $conf -Encoding ascii

# cloudbase-init refuses to process metadata until sysprep GeneralizationState==7,
# but this image's OOBE leaves it at 4 (it stalls forever "Waiting for sysprep
# completion"). SetupComplete.cmd runs at deploy-time setup completion and finalizes
# it to 7 so cloudbase-init proceeds - fully hands-off.
$scriptsDir = Join-Path $env:windir 'Setup\Scripts'
New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null
Set-Content -Path (Join-Path $scriptsDir 'SetupComplete.cmd') -Encoding ascii -Value @'
@echo off
reg add "HKLM\SYSTEM\Setup\Status\SysprepStatus" /v GeneralizationState /t REG_DWORD /d 7 /f
'@

# Service auto-starts and runs once per instance-id (so each cloned VM re-applies).
$svc = Get-Service -Name 'cloudbase-init' -ErrorAction SilentlyContinue
if ($svc) {
    Set-Service -Name 'cloudbase-init' -StartupType Automatic
    Write-Host "cloudbase-init installed; service set to Automatic."
} else {
    throw "cloudbase-init service not found after install (see $log)."
}
Write-Host "=== cloudbase-init install complete ==="
