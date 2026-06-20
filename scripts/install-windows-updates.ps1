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
# Direct .msu from the Update Catalog CDN, pinned to bypass the MSCatalog scrape
# (catalog.microsoft.com persistently errored for MSCatalog's in-guest requests even
# though the catalog itself is up). This is the combined SSU+LCU for KB5094125
# (Server 2025 / "server operating system 24H2", build 26100.32995, ~2.4 GB). Bump
# this URL together with $Kb each month - re-derive it from the catalog DownloadDialog
# for the new KB's update GUID. Set to '' to fall back to the MSCatalog scrape.
$MsuUrl = 'https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/7bb8f378-6d48-4161-ac28-0be28444e642/public/windows11.0-kb5094125-x64_8e89fa4917df313fe118b9fe150611975ab92565.msu'

$dir = 'C:\Windows\Temp\updates'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$msu = $null

# catalog.microsoft.com routinely returns transient "site has encountered an error"
# responses, which fail a single MSCatalog scrape. Retry with backoff so one hiccup
# doesn't leave the base unpatched. For full determinism, pin $MsuUrl above instead.
$maxAttempts = 4
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    try {
        if ($MsuUrl) {
            Write-Host "=== Downloading update from $MsuUrl (attempt $attempt/$maxAttempts) ==="
            $msu = Join-Path $dir 'update.msu'
            # curl.exe, NOT Invoke-WebRequest: this is a ~2.4 GB file over QEMU's slow
            # user-mode NAT, and IWR has no transfer-stall timeout (would hang forever).
            # Generous --max-time (1 h) for the size; --speed-time aborts a true stall.
            & curl.exe -L -f --connect-timeout 30 --max-time 3600 --speed-limit 5000 --speed-time 120 -o $msu $MsuUrl
            if ($LASTEXITCODE -ne 0) { throw "curl failed with exit code $LASTEXITCODE" }
        } else {
            Write-Host "=== Fetching $Kb from the Microsoft Update Catalog via MSCatalog (attempt $attempt/$maxAttempts) ==="
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
        if ($msu -and (Test-Path $msu)) { break }
    } catch {
        Write-Warning "attempt $attempt/$maxAttempts to obtain the update failed: $_"
        $msu = $null
    }
    if ($attempt -lt $maxAttempts) { Start-Sleep -Seconds (20 * $attempt) }
}
if (-not ($msu -and (Test-Path $msu))) {
    Write-Warning "Could not obtain the cumulative update after $maxAttempts attempts. Continuing without it - the base is still usable; rebuild when the catalog is reachable, or pin a direct .msu URL in `$MsuUrl."
    $msu = $null
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
