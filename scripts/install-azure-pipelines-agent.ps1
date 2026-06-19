# Bundle the Azure Pipelines agent into the golden image (NOT configured here).
# Uses the trimmed "pipelines-agent" package (no legacy Node handlers) - smaller
# than the full "vsts-agent" package. Enrollment to a pool happens later, at
# provision time, via scripts/enroll-azure-pipelines-agent.ps1.
$ErrorActionPreference = 'Stop'

# Latest 4.x agent. Bump $Version + $Sha256 together from:
#   https://github.com/microsoft/azure-pipelines-agent/releases
$Version = '4.275.0'
$Sha256  = '1E05A0F6081393A948092B19B21FEF8A52B7DC956D543C1F9C6A9320AA7570D0'
$Url     = "https://download.agent.dev.azure.com/agent/$Version/pipelines-agent-win-x64-$Version.zip"

$AgentDir = 'C:\azp\agent'
$Zip      = "$env:TEMP\pipelines-agent-$Version.zip"

Write-Host "=== Bundling Azure Pipelines agent $Version (trimmed package) ==="
New-Item -ItemType Directory -Force -Path $AgentDir | Out-Null

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Write-Host "Downloading $Url ..."
Invoke-WebRequest -Uri $Url -OutFile $Zip -UseBasicParsing

$actual = (Get-FileHash -Algorithm SHA256 -Path $Zip).Hash
if ($actual -ne $Sha256) {
    throw "SHA256 mismatch for agent package: expected $Sha256, got $actual"
}
Write-Host "Checksum OK. Extracting to $AgentDir ..."
Expand-Archive -Path $Zip -DestinationPath $AgentDir -Force
Remove-Item $Zip -Force

if (-not (Test-Path "$AgentDir\config.cmd")) {
    throw "config.cmd not found after extraction - agent package layout changed?"
}

# Record what we bundled so the enrollment script / audits can read it.
[pscustomobject]@{
    version = $Version
    package = "pipelines-agent-win-x64-$Version.zip"
    source  = $Url
} | ConvertTo-Json | Set-Content -Encoding ascii "$AgentDir\.bundled-agent.json"

Write-Host "Azure Pipelines agent $Version staged at $AgentDir (unconfigured)."
