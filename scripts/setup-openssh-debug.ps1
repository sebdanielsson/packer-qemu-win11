# Debug provisioner: install OpenSSH Server + authorized key for interactive testing
# Use this instead of install-visual-studio.ps1 to get SSH access into the built image.
$ErrorActionPreference = 'Stop'

Write-Host "Installing OpenSSH Server..."
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0

Write-Host "Enabling and starting sshd..."
Set-Service -Name sshd -StartupType 'Automatic'
Start-Service sshd

# Firewall rule - ensure it exists and applies to ALL profiles (Public/Private/Domain)
$fwRule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
if ($fwRule) {
    Set-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -Enabled True -Profile Any
} else {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -Profile Any
}

# The VM may be detected as a "Public" network on first boot - set to Private so rules apply
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private

# For Administrators group, Windows OpenSSH uses a special file instead of per-user authorized_keys
# See: https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_keymanagement
Write-Host "Installing authorized key..."
$authKeysFile = "C:\ProgramData\ssh\administrators_authorized_keys"
$pubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMUvvjkgJJ8z+4rxR0TNHLOLmljKh+bGS+UqrKSGB7lN"
Set-Content -Path $authKeysFile -Value $pubKey -Encoding UTF8

# Fix permissions: must be owned by SYSTEM/Administrators only (OpenSSH strict check)
icacls $authKeysFile /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F" | Out-Null

Write-Host "OpenSSH debug setup complete. Connect with: ssh builder@<vm-ip>"
