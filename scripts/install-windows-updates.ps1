# Bake the latest cumulative update into the BASE image (offline, via DISM).
# Patch strategy: rebuild the base monthly and bump $Kb to the current Server 2025
# cumulative update from https://support.microsoft.com/...windows-server-2025-update-history
# Runtime Windows Update stays disabled (determinism), so updates land via rebuilds.
#
# Best-effort + ASCII only: a flaky catalog/download must never fail the build.
$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Bump monthly. Latest Server 2025 (build 26100) cumulative update.
$Kb = 'KB5094125'
# Optional: set a direct .msu URL to bypass the Update Catalog entirely.
$MsuUrl = ''

$dir = 'C:\Windows\Temp\updates'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$msu = $null

try {
    if ($MsuUrl) {
        Write-Host "=== Downloading update from $MsuUrl ==="
        $msu = Join-Path $dir 'update.msu'
        Invoke-WebRequest -Uri $MsuUrl -OutFile $msu -UseBasicParsing
    } else {
        Write-Host "=== Fetching $Kb from the Microsoft Update Catalog (via MSCatalog) ==="
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction Stop | Out-Null
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        if (-not (Get-Module -ListAvailable -Name MSCatalog)) {
            Install-Module -Name MSCatalog -Force -Scope AllUsers -ErrorAction Stop
        }
        Import-Module MSCatalog
        $upd = Get-MSCatalogUpdate -Search $Kb -ErrorAction Stop |
            Where-Object { $_.Title -match 'x64' -and $_.Title -match 'Cumulative' } |
            Sort-Object -Property LastUpdated -Descending | Select-Object -First 1
        if (-not $upd) { throw "no x64 cumulative update found for $Kb in the catalog" }
        Write-Host "  found: $($upd.Title)"
        $upd | Save-MSCatalogUpdate -Destination $dir -ErrorAction Stop
        $msu = (Get-ChildItem -Path "$dir\*.msu" | Select-Object -First 1).FullName
    }
} catch {
    Write-Warning "Could not obtain the cumulative update ($_). Continuing without it - the base is still usable; rebuild when the catalog is reachable."
}

if ($msu -and (Test-Path $msu)) {
    Write-Host "=== Applying $(Split-Path $msu -Leaf) via DISM ==="
    & Dism.exe /Online /Add-Package /PackagePath:"$msu" /Quiet /NoRestart
    $rc = $LASTEXITCODE
    # 0 = ok, 3010 = ok+reboot-needed (the build reboots next), 0x800f081e = not applicable (already current)
    if ($rc -in @(0, 3010)) { Write-Host "Cumulative update applied (DISM $rc)." }
    else { Write-Warning "DISM returned $rc; continuing." }
    Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
} else {
    Write-Host "No update package to apply."
}
Write-Host "=== Windows updates step complete ==="
exit 0
