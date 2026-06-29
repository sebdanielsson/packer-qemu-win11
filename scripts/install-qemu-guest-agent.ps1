# Install the QEMU guest agent (via the virtio-win guest tools) into the golden
# image. This gives OpenShift Virtualization / KubeVirt proper guest integration:
# reported IP + guest OS info (AgentConnected=True), graceful shutdown, and
# filesystem quiesce for online snapshots. The "QEMU Guest Agent" service survives
# sysprep /generalize and auto-starts after OOBE on every deployed VM.
#
# Run at BUILD time, before sysprep-generalize.ps1.
$ErrorActionPreference = 'Stop'

# Bump $Version + $Sha256 together. Versions + checksums:
#   https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/
$Version = '0.1.285-1'
$Sha256  = 'C8B4A9FE87E1FC5D8E843495E082DEA53420587FE04740B1084D85089343F04D'
$Url     = "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-$Version/virtio-win-guest-tools.exe"

$Exe = "$env:TEMP\virtio-win-guest-tools-$Version.exe"

Write-Host "=== Installing QEMU guest agent (virtio-win guest tools $Version) ==="
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Retry transient download failures over QEMU's slow NAT (mirror install-*-runner.ps1).
$ok = $false
for ($i = 1; $i -le 4; $i++) {
    try {
        & curl.exe -L -f --connect-timeout 30 --max-time 1200 --speed-limit 10240 --speed-time 60 -o $Exe $Url
        if ($LASTEXITCODE -ne 0) { throw "curl failed with exit code $LASTEXITCODE" }
        if ((Get-Item $Exe).Length -lt 1MB) { throw "download too small ($((Get-Item $Exe).Length) bytes) - partial/blocked" }
        $ok = $true; break
    } catch {
        Write-Host "  download attempt $i/4 failed: $_"
        Start-Sleep -Seconds (10 * $i)
    }
}
if (-not $ok) { throw "failed to download virtio-win guest tools after 4 attempts: $Url" }

$actual = (Get-FileHash -Algorithm SHA256 -Path $Exe).Hash
if ($actual -ne $Sha256) { throw "SHA256 mismatch: expected $Sha256, got $actual" }
Write-Host "Checksum OK. Installing (silent)..."

# /install /quiet /norestart installs the virtio drivers + QEMU guest agent + SPICE
# agent. Exit 3010 == success-with-reboot-pending (a windows-restart provisioner or
# the sysprep reboot clears it); treat it as success.
$p = Start-Process -FilePath $Exe -ArgumentList '/install','/quiet','/norestart' -Wait -PassThru
if ($p.ExitCode -notin 0, 3010) { throw "virtio-win guest tools installer failed with exit code $($p.ExitCode)" }

# Make sure the agent service is set to auto-start (it is by default; be explicit).
$svc = Get-Service -Name 'QEMU-GA' -ErrorAction SilentlyContinue
if (-not $svc) { $svc = Get-Service -Name 'QEMU Guest Agent' -ErrorAction SilentlyContinue }
if ($svc) {
    Set-Service -Name $svc.Name -StartupType Automatic
    Write-Host "QEMU guest agent installed; service '$($svc.Name)' set to Automatic (state: $($svc.Status))."
} else {
    Write-Host "WARNING: QEMU guest agent service not found after install - verify the guest-tools package."
}
Write-Host "=== QEMU guest agent install complete ==="
