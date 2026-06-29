<#
.SYNOPSIS
    Enroll the pre-bundled Azure Pipelines agent into an agent pool (group).

.DESCRIPTION
    Run this at PROVISION time (on the deployed OpenShift/Proxmox VM), not in the
    golden image. It configures the agent that install-azure-pipelines-agent.ps1
    already staged at C:\azp\agent, registering it with your (on-prem) Azure
    DevOps Server and installing it as an auto-start Windows service.

    Secrets (org URL, PAT, pool) can come from parameters OR from a JSON file at
    C:\azp\enroll.json - which is the hook OpenShift/KubeVirt (or Proxmox cloud-
    init) drops in at deploy time from a Secret/ConfigMap. Example enroll.json:
        {
          "OrgUrl":    "https://devops.example.local",
          "Pool":      "windows-pool",
          "Token":     "<PAT>",
          "AgentName": "",            // blank => computer name
          "Replace":   true
        }

.NOTES
    OrgUrl must match where the agent POOL lives - it is NOT a project/repo URL:
      - Azure DevOps Server, server-level (organization) pool: the server ROOT,
        e.g. https://devops.example.local  (do NOT append a collection or project)
      - Azure DevOps Server, collection-scoped pool: https://<server>/<collection>
      - Azure DevOps (cloud): https://dev.azure.com/<org>
    PAT needs the "Agent Pools (read & manage)" scope.
#>
[CmdletBinding()]
param(
    [string]$OrgUrl,
    [string]$Pool,
    [string]$Token,
    [string]$AgentName = $env:COMPUTERNAME,
    [string]$Work = '_work',
    [switch]$Replace,
    # Optional: run the service under a specific account instead of NETWORK SERVICE.
    [string]$WindowsLogonAccount,
    [string]$WindowsLogonPassword,
    [string]$ConfigFile = 'C:\azp\enroll.json'
)
$ErrorActionPreference = 'Stop'
$AgentDir = 'C:\azp\agent'

# Layer in values from the config file for any parameter not passed explicitly.
if (Test-Path $ConfigFile) {
    Write-Host "Loading enrollment config from $ConfigFile"
    $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    if (-not $OrgUrl   -and $cfg.OrgUrl)    { $OrgUrl    = $cfg.OrgUrl }
    if (-not $Pool     -and $cfg.Pool)      { $Pool      = $cfg.Pool }
    if (-not $Token    -and $cfg.Token)     { $Token     = $cfg.Token }
    if ($cfg.AgentName)                     { $AgentName = $cfg.AgentName }
    if ($cfg.Replace)                       { $Replace   = [bool]$cfg.Replace }
}
if (-not $AgentName) { $AgentName = $env:COMPUTERNAME }

foreach ($p in 'OrgUrl','Pool','Token') {
    if (-not (Get-Variable $p -ValueOnly)) { throw "Missing required value: $p (pass -$p or set it in $ConfigFile)" }
}
if (-not (Test-Path "$AgentDir\config.cmd")) { throw "Agent not bundled at $AgentDir - run install-azure-pipelines-agent.ps1 in the image first." }

$cfgArgs = @(
    '--unattended',
    '--url',   $OrgUrl,
    '--auth',  'pat',
    '--token', $Token,
    '--pool',  $Pool,
    '--agent', $AgentName,
    '--work',  $Work,
    '--runAsService'
)
if ($Replace)              { $cfgArgs += '--replace' }
if ($WindowsLogonAccount)  { $cfgArgs += @('--windowsLogonAccount', $WindowsLogonAccount,
                                           '--windowsLogonPassword', $WindowsLogonPassword) }

Write-Host "Configuring agent '$AgentName' -> pool '$Pool' at $OrgUrl ..."
Push-Location $AgentDir
try {
    & "$AgentDir\config.cmd" @cfgArgs
    if ($LASTEXITCODE -ne 0) { throw "agent config.cmd failed with exit code $LASTEXITCODE" }
} finally {
    Pop-Location
}
Write-Host "Agent '$AgentName' enrolled and running as a service."
