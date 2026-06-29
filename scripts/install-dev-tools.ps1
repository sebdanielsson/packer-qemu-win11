# Extra dev tooling bundled into the image: mise (dev-tool version manager) and
# the latest stable Google Chrome. ASCII only (Windows PowerShell reads .ps1 as
# ANSI; non-ASCII breaks parsing).
#
# Best-effort: a flaky download must NEVER fail a multi-hour build. Each tool is
# retried + validated; on persistent failure we log a warning and continue (the
# image is still useful, and verification will flag a missing tool).
$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Loosen the machine execution policy so CI tasks and the enroll-*.ps1 / runtime
# proxy-CA scripts run .ps1 files without prompts - expected on a build box.
# Done here (dev-tools stage), deliberately NOT baked into the stricter base image.
Set-ExecutionPolicy -Scope LocalMachine -ExecutionPolicy Unrestricted -Force
# PowerShell 7 keeps its own policy; set it too if pwsh is present.
if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    pwsh -NoProfile -Command "Set-ExecutionPolicy -Scope LocalMachine -ExecutionPolicy Unrestricted -Force"
}

# Enable Windows Developer Mode (sideload loose/unsigned apps, create symlinks
# without elevation, etc.) - the registry equivalent of the Settings > System >
# For developers > Developer Mode toggle.
$devKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
New-Item -Path $devKey -Force | Out-Null
New-ItemProperty -Path $devKey -Name AllowDevelopmentWithoutDevLicense -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $devKey -Name AllowAllTrustedApps              -Value 1 -PropertyType DWord -Force | Out-Null

function Get-FileWithRetry {
    param($Url, $OutFile, [int]$MinBytes = 1, [string]$Sha256 = $null, [int]$Tries = 4)
    for ($i = 1; $i -le $Tries; $i++) {
        try {
            Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
            # Use curl.exe (shipped in Server 2025), NOT Invoke-WebRequest: IWR has no
            # transfer/inactivity timeout, so a mid-download stall over QEMU's slow
            # user-mode NAT hangs forever (this wedged the 150 MB Chrome download for
            # the whole 60-min provisioner timeout and errored the build). curl's
            # --max-time hard-caps each attempt and --speed-time aborts a stalled
            # transfer, so a download can never hang the build.
            & curl.exe -L -f --connect-timeout 30 --max-time 900 `
                --speed-limit 10240 --speed-time 60 -o $OutFile $Url
            if ($LASTEXITCODE -ne 0) { throw "curl failed with exit code $LASTEXITCODE" }
            $len = (Get-Item $OutFile).Length
            if ($len -lt $MinBytes) { throw "too small ($len bytes, expected >= $MinBytes) - partial/blocked download" }
            if ($Sha256) {
                $h = (Get-FileHash -Algorithm SHA256 -Path $OutFile).Hash
                if ($h -ne $Sha256) { throw "sha256 mismatch ($h)" }
            } else {
                # No fixed checksum (always-latest URL): sanity-check it's a real MSI
                # (OLE compound-file magic D0 CF 11 E0) when the name ends in .msi.
                if ($OutFile -match '\.msi$') {
                    $fs = [IO.File]::OpenRead($OutFile); $b = New-Object byte[] 8; [void]$fs.Read($b, 0, 8); $fs.Close()
                    if (-not ($b[0] -eq 0xD0 -and $b[1] -eq 0xCF -and $b[2] -eq 0x11 -and $b[3] -eq 0xE0)) {
                        throw "not a valid MSI (bad magic bytes)"
                    }
                }
            }
            return $true
        } catch {
            Write-Host "  download attempt $i/$Tries failed: $_"
            Start-Sleep -Seconds (5 * $i)
        }
    }
    return $false
}

Write-Host "=== Installing Google Chrome (latest stable, enterprise MSI) ==="
$chromeMsi = "$env:TEMP\chrome-enterprise.msi"
# always-latest stable enterprise build (not pinned); ~150 MB, so require >= 100 MB
if (Get-FileWithRetry -Url 'https://dl.google.com/edgedl/chrome/install/GoogleChromeStandaloneEnterprise64.msi' `
        -OutFile $chromeMsi -MinBytes 100MB) {
    # Bound msiexec: if Windows Installer is wedged (e.g. a pending reboot holds the
    # _MSIExecute mutex), -Wait would block until the provisioner timeout and ERROR
    # the whole build. Wait at most 15 min, then kill and continue (best-effort).
    $p = Start-Process msiexec.exe -ArgumentList '/i', $chromeMsi, '/qn', '/norestart' -PassThru
    if ($p.WaitForExit(900000)) {
        if ($p.ExitCode -in @(0, 3010)) { Write-Host "Chrome installed." }
        else { Write-Warning "Chrome MSI returned $($p.ExitCode); continuing without Chrome." }
    } else {
        Write-Warning "Chrome msiexec did not finish within 15 min; killing it and continuing without Chrome."
        try { $p.Kill() } catch {}
        Get-Process msiexec -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $chromeMsi -Force -ErrorAction SilentlyContinue
} else {
    Write-Warning "Chrome download failed after retries; continuing without Chrome."
}

Write-Host "=== Installing mise (dev-tool version manager) ==="
# Bump $MiseVersion + $MiseSha256 together from https://github.com/jdx/mise/releases
$MiseVersion = '2026.6.11'
$MiseSha256  = 'AE6FA8C6D88F4D368E589B6C9936C09F552CDA717600123369DCA007CED33ECC'
$miseZip = "$env:TEMP\mise.zip"
if (Get-FileWithRetry -Url "https://github.com/jdx/mise/releases/download/v$MiseVersion/mise-v$MiseVersion-windows-x64.zip" `
        -OutFile $miseZip -Sha256 $MiseSha256) {
    $dest = 'C:\Program Files\mise'
    $tmp  = "$env:TEMP\mise-extract"
    Remove-Item $dest, $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -Path $miseZip -DestinationPath $tmp -Force       # zip has a top-level 'mise\' dir
    Move-Item -Path "$tmp\mise" -Destination $dest
    Remove-Item $miseZip, $tmp -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path "$dest\bin\mise.exe") {
        $bin = "$dest\bin"
        # mise writes per-tool shims to %LOCALAPPDATA%\mise\shims; putting that on
        # PATH makes `mise use -g <tool>` directly invocable (no `mise exec`/activate
        # needed) in CI shells. The build runs as builder, so this resolves to
        # C:\Users\builder\AppData\Local\mise\shims.
        $shims = Join-Path $env:LOCALAPPDATA 'mise\shims'
        New-Item -ItemType Directory -Force -Path $shims | Out-Null
        $machPath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        foreach ($d in @($bin, $shims)) { if ($machPath -notlike "*$d*") { $machPath = "$machPath;$d" } }
        [Environment]::SetEnvironmentVariable('Path', $machPath, 'Machine')
        $env:Path = "$env:Path;$bin;$shims"
        & "$bin\mise.exe" reshim 2>$null   # create the shims dir now
        Write-Host "mise $MiseVersion installed at $dest; bin + shims on PATH ($shims)."
    } else { Write-Warning "mise.exe missing after extraction; continuing without mise." }
} else {
    Write-Warning "mise download failed after retries; continuing without mise."
}

Write-Host "=== dev tools step complete ==="
exit 0
