# Install the QEMU guest agent into the golden image so OpenShift Virtualization /
# KubeVirt gets proper guest integration: reported IP + guest OS info
# (AgentConnected=True), graceful shutdown, and filesystem quiesce for online
# snapshots. The "QEMU Guest Agent" service survives sysprep /generalize and
# auto-starts after OOBE on every deployed VM.
#
# We install ONLY the standalone qemu-ga MSI - NOT the full virtio-win-guest-tools
# bundle. The bundle tries to (re)install every virtio driver, and replacing the
# in-use storage/network driver headless HANGS the installer (it wedged a build
# for the full provisioner timeout). The base image already has the virtio drivers
# from install time; here we only want the agent service.
#
# Best-effort + bounded: a flaky download or a stuck msiexec must NEVER waste a
# multi-hour build. Run at BUILD time, before sysprep-generalize.ps1.
$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Bump $Version + $Sha256 together. Standalone qemu-ga builds:
#   https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-qemu-ga/
$Version = '110.0.2-1.el10'
$Sha256  = 'C50EA2E7C04730A1097AB6C112138645BE4DA26015518329DAEBE8D3630E0790'
$Url     = "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-qemu-ga/qemu-ga-win-$Version/qemu-ga-x86_64.msi"

$Msi = "$env:TEMP\qemu-ga-x86_64.msi"

Write-Host "=== Installing QEMU guest agent (qemu-ga $Version) ==="

# Retry transient download failures over QEMU's slow NAT (mirror the other scripts).
$ok = $false
for ($i = 1; $i -le 4; $i++) {
    try {
        & curl.exe -L -f --connect-timeout 30 --max-time 600 --speed-limit 10240 --speed-time 60 -o $Msi $Url
        if ($LASTEXITCODE -ne 0) { throw "curl failed with exit code $LASTEXITCODE" }
        if ((Get-Item $Msi).Length -lt 1MB) { throw "download too small ($((Get-Item $Msi).Length) bytes) - partial/blocked" }
        $ok = $true; break
    } catch {
        Write-Host "  download attempt $i/4 failed: $_"
        Start-Sleep -Seconds (10 * $i)
    }
}
if (-not $ok) {
    Write-Warning "qemu-ga download failed after retries; continuing WITHOUT the guest agent (verification will flag it)."
    Write-Host "=== QEMU guest agent install complete (skipped) ==="
    exit 0
}

$actual = (Get-FileHash -Algorithm SHA256 -Path $Msi).Hash
if ($actual -ne $Sha256) {
    Write-Warning "qemu-ga SHA256 mismatch (expected $Sha256, got $actual); continuing WITHOUT the guest agent."
    exit 0
}
Write-Host "Checksum OK. Installing qemu-ga MSI (silent)..."

# Bound msiexec: a wedged Windows Installer would otherwise block until the
# provisioner timeout and error the whole build. Wait at most 10 min, then kill.
$log = "$env:TEMP\qemu-ga-msi.log"
$p = Start-Process msiexec.exe -PassThru -ArgumentList @(
    '/i', "`"$Msi`"", '/qn', '/norestart', '/l*v', "`"$log`""
)
if ($p.WaitForExit(600000)) {
    if ($p.ExitCode -notin 0, 3010) {
        Write-Warning "qemu-ga MSI returned $($p.ExitCode) (see $log); continuing."
    }
} else {
    Write-Warning "qemu-ga msiexec did not finish within 10 min; killing it and continuing."
    try { $p.Kill() } catch {}
    Get-Process msiexec -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
Remove-Item $Msi -Force -ErrorAction SilentlyContinue

# Make sure the agent service is set to auto-start (it is by default; be explicit).
$svc = Get-Service -Name 'QEMU-GA' -ErrorAction SilentlyContinue
if (-not $svc) { $svc = Get-Service -Name 'QEMU Guest Agent' -ErrorAction SilentlyContinue }
if ($svc) {
    Set-Service -Name $svc.Name -StartupType Automatic
    Write-Host "QEMU guest agent installed; service '$($svc.Name)' set to Automatic (state: $($svc.Status))."
} else {
    Write-Warning "QEMU guest agent service not found after install - check $log."
}
Write-Host "=== QEMU guest agent install complete ==="
exit 0
