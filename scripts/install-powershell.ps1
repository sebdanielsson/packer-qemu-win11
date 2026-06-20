# Install the latest stable PowerShell 7 (MSI). Lives in the BASE image since it is
# broadly useful. ASCII only (Windows PowerShell reads .ps1 as ANSI).
#
# Best-effort + retried: this runs right after the cumulative update, when Windows
# Installer can still be BUSY / a reboot pending (msiexec then fails - observed exit
# ~1601/16001, which used to abort the whole ~5 h base build). Retry through that
# transient state and NEVER fail the build (verification flags a missing pwsh).
$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "=== Installing latest stable PowerShell 7 ==="
$pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
$installer = "$env:TEMP\install-powershell.ps1"
$ok = $false
for ($i = 1; $i -le 5; $i++) {
    try {
        # curl.exe (not IWR): bounded download, no transfer-stall hang over the NAT.
        & curl.exe -L -f --connect-timeout 30 --max-time 300 -o $installer 'https://aka.ms/install-powershell.ps1'
        if ($LASTEXITCODE -ne 0) { throw "curl helper download failed ($LASTEXITCODE)" }
        & $installer -UseMSI -Quiet
        if (Test-Path $pwsh) { $ok = $true; break }
        throw "pwsh.exe not present after install attempt (Windows Installer may be busy post-update)"
    } catch {
        Write-Host "  PS7 install attempt $i/5 failed: $_"
        Start-Sleep -Seconds (30 * $i)
    }
}
if ($ok) { Write-Host "PowerShell 7 installed ($(& $pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'))." }
else { Write-Warning "PowerShell 7 not installed after retries; continuing (base still usable, verification will flag it)." }
exit 0
