# Bundle the GitHub Actions runner into the golden image (NOT configured here).
# Registration happens later, at provision time, via
# scripts/enroll-github-runner.ps1. Mirrors install-azure-pipelines-agent.ps1 so
# one image can become EITHER an Azure Pipelines agent OR a GitHub runner,
# decided at boot/provision time.
$ErrorActionPreference = 'Stop'

# Latest runner. Bump $Version + $Sha256 together from:
#   https://github.com/actions/runner/releases
$Version = '2.335.1'
$Sha256  = 'EB65C95277AF42BCF3778A799C41359D224BA2A67B4DE26B7CEA1729B09C803D'
$Url     = "https://github.com/actions/runner/releases/download/v$Version/actions-runner-win-x64-$Version.zip"

$Dir = 'C:\actions-runner'
$Zip = "$env:TEMP\actions-runner-$Version.zip"

Write-Host "=== Bundling GitHub Actions runner $Version ==="
New-Item -ItemType Directory -Force -Path $Dir | Out-Null

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Write-Host "Downloading $Url ..."
# Retry transient download failures (still fail hard after 4 tries / on checksum
# mismatch - the runner IS the point of the image, so a missing runner must error).
$ok = $false
for ($i = 1; $i -le 4; $i++) {
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Zip -UseBasicParsing -TimeoutSec 120
        if ((Get-Item $Zip).Length -lt 1MB) { throw "download too small ($((Get-Item $Zip).Length) bytes) - partial/blocked" }
        $ok = $true; break
    } catch {
        Write-Host "  download attempt $i/4 failed: $_"
        Start-Sleep -Seconds (10 * $i)
    }
}
if (-not $ok) { throw "failed to download runner package after 4 attempts: $Url" }

$actual = (Get-FileHash -Algorithm SHA256 -Path $Zip).Hash
if ($actual -ne $Sha256) {
    throw "SHA256 mismatch for runner package: expected $Sha256, got $actual"
}
Write-Host "Checksum OK. Extracting to $Dir ..."
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($Zip, $Dir)
Remove-Item $Zip -Force

if (-not (Test-Path "$Dir\config.cmd")) {
    throw "config.cmd not found after extraction - runner package layout changed?"
}

[pscustomobject]@{
    version = $Version
    package = "actions-runner-win-x64-$Version.zip"
    source  = $Url
} | ConvertTo-Json | Set-Content -Encoding ascii "$Dir\.bundled-runner.json"

Write-Host "GitHub Actions runner $Version staged at $Dir (unconfigured, no service)."
