os_name = "windows"
os_version = "2025"
os_arch = "x64"

# Local evaluation ISO already staged on the Proxmox host.
# (Windows Server 2025 Standard/Datacenter Evaluation, 180-day.)
# Using a local path avoids re-downloading ~7.5 GB on every build.
iso_url = "/chungus/isos/windows-server-2025.iso"
iso_checksum = "none"

# WinRM credentials - set these securely, do not commit to version control
winrm_username = "builder"
winrm_password = "changeme"
