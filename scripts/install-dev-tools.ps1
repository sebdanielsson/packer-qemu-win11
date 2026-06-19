# Extra dev tooling bundled into the image: mise (dev-tool version manager) and
# the latest stable Google Chrome. ASCII only (Windows PowerShell reads .ps1 as
# ANSI; non-ASCII breaks parsing).
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "=== Installing Google Chrome (latest stable, enterprise MSI) ==="
# This URL always serves the current stable enterprise build, so it is not pinned.
$chromeMsi = "$env:TEMP\chrome-enterprise.msi"
Invoke-WebRequest -Uri 'https://dl.google.com/edgedl/chrome/install/GoogleChromeStandaloneEnterprise64.msi' `
    -OutFile $chromeMsi -UseBasicParsing
$p = Start-Process msiexec.exe -ArgumentList '/i', $chromeMsi, '/qn', '/norestart' -Wait -PassThru
if ($p.ExitCode -notin @(0, 3010)) { throw "Chrome MSI install failed with exit code $($p.ExitCode)" }
Remove-Item $chromeMsi -Force
Write-Host "Chrome installed."

Write-Host "=== Installing mise (dev-tool version manager) ==="
# Bump $MiseVersion + $MiseSha256 together from https://github.com/jdx/mise/releases
$MiseVersion = '2026.6.11'
$MiseSha256  = 'AE6FA8C6D88F4D368E589B6C9936C09F552CDA717600123369DCA007CED33ECC'
$miseZip = "$env:TEMP\mise.zip"
Invoke-WebRequest -Uri "https://github.com/jdx/mise/releases/download/v$MiseVersion/mise-v$MiseVersion-windows-x64.zip" `
    -OutFile $miseZip -UseBasicParsing
$actual = (Get-FileHash -Algorithm SHA256 -Path $miseZip).Hash
if ($actual -ne $MiseSha256) { throw "mise SHA256 mismatch: expected $MiseSha256, got $actual" }

$dest = 'C:\Program Files\mise'
$tmp  = "$env:TEMP\mise-extract"
Remove-Item $dest, $tmp -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive -Path $miseZip -DestinationPath $tmp -Force      # zip contains a top-level 'mise\' dir
Move-Item -Path "$tmp\mise" -Destination $dest
Remove-Item $miseZip, $tmp -Recurse -Force -ErrorAction SilentlyContinue
if (-not (Test-Path "$dest\bin\mise.exe")) { throw "mise.exe not found after extraction" }

# Add mise to the machine PATH (persists through generalize; visible to all sessions).
$bin = "$dest\bin"
$machPath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
if ($machPath -notlike "*$bin*") {
    [Environment]::SetEnvironmentVariable('Path', "$machPath;$bin", 'Machine')
    Write-Host "Added $bin to machine PATH."
}
Write-Host "mise $MiseVersion installed at $dest."
