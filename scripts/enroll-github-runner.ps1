<#
.SYNOPSIS
    Register the pre-bundled GitHub Actions runner with a repo/org.

.DESCRIPTION
    Run this at PROVISION time, not in the golden image. It configures the
    runner that install-github-runner.ps1 staged at C:\actions-runner.

    Per design, this does NOT install an auto-start service by default - so a
    freshly-booted VM stays neutral until something decides "Azure vs GitHub".
    Pass -AsService to install the runner as a service, and/or -Start to launch
    run.cmd once now.

    Secrets can come from parameters OR C:\actions-runner\enroll.json (the drop-in
    hook for KubeVirt/cloud-init). Example enroll.json:
        {
          "Url":    "https://github.com/my-org",     // org- or repo-level
          "Token":  "<registration-token>",          // short-lived, from GitHub API/UI
          "Labels": "windows,vs2026,self-hosted",
          "RunnerGroup": "Default",
          "Name":   "",                                // blank => computer name
          "Ephemeral": false,
          "Replace": true
        }

.NOTES
    The registration token is short-lived (~1h). Generate it at provision time
    via the GitHub API (POST .../actions/runners/registration-token) using a PAT,
    or paste one from Settings > Actions > Runners. A repo/org runner is chosen by
    the form of -Url.
#>
[CmdletBinding()]
param(
    [string]$Url,
    [string]$Token,
    [string]$Labels = 'self-hosted,windows,vs2026',
    [string]$RunnerGroup = 'Default',
    [string]$Name = $env:COMPUTERNAME,
    [string]$Work = '_work',
    [switch]$Ephemeral,
    [switch]$Replace,
    [switch]$AsService,                 # default OFF: do not autostart yet
    [switch]$Start,                     # optionally launch run.cmd once after config
    [string]$ConfigFile = 'C:\actions-runner\enroll.json'
)
$ErrorActionPreference = 'Stop'
$Dir = 'C:\actions-runner'

if (Test-Path $ConfigFile) {
    Write-Host "Loading enrollment config from $ConfigFile"
    $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    if (-not $Url    -and $cfg.Url)        { $Url    = $cfg.Url }
    if (-not $Token  -and $cfg.Token)      { $Token  = $cfg.Token }
    if ($cfg.Labels)                       { $Labels = $cfg.Labels }
    if ($cfg.RunnerGroup)                  { $RunnerGroup = $cfg.RunnerGroup }
    if ($cfg.Name)                         { $Name   = $cfg.Name }
    if ($cfg.Ephemeral)                    { $Ephemeral = [bool]$cfg.Ephemeral }
    if ($cfg.Replace)                      { $Replace   = [bool]$cfg.Replace }
}
if (-not $Name) { $Name = $env:COMPUTERNAME }

foreach ($p in 'Url','Token') {
    if (-not (Get-Variable $p -ValueOnly)) { throw "Missing required value: $p (pass -$p or set it in $ConfigFile)" }
}
if (-not (Test-Path "$Dir\config.cmd")) { throw "Runner not bundled at $Dir - run install-github-runner.ps1 in the image first." }

$cfgArgs = @(
    '--unattended',
    '--url',         $Url,
    '--token',       $Token,
    '--name',        $Name,
    '--labels',      $Labels,
    '--runnergroup', $RunnerGroup,
    '--work',        $Work
)
if ($Replace)   { $cfgArgs += '--replace' }
if ($Ephemeral) { $cfgArgs += '--ephemeral' }
if ($AsService) { $cfgArgs += @('--runasservice') }   # NOT used unless explicitly requested

Write-Host "Configuring GitHub runner '$Name' -> $Url (service=$($AsService.IsPresent)) ..."
Push-Location $Dir
try {
    & "$Dir\config.cmd" @cfgArgs
    if ($LASTEXITCODE -ne 0) { throw "runner config.cmd failed with exit code $LASTEXITCODE" }
    if ($Start -and -not $AsService) {
        Write-Host "Starting run.cmd (foreground session)..."
        Start-Process -FilePath "$Dir\run.cmd" -WorkingDirectory $Dir
    }
} finally {
    Pop-Location
}
Write-Host "GitHub runner '$Name' configured$(if($AsService){' as a service'}else{' (no service; not autostarting)'})."
