# BASE image build: Windows Server 2025 from ISO + virtio drivers + Windows
# Updates + harden + PowerShell 7. NOT generalized - it is the parent that the
# build-server (and other) images layer on top of. Build with:
#   packer build -only='base.*' ...
source "qemu" "base" {
  vm_name          = local.base_name
  output_directory = var.output_dir

  efi_boot          = true
  efi_firmware_code = var.efi_firmware_code
  efi_firmware_vars = var.efi_firmware_vars

  # vTPM disabled: the host's swtpm is apparmor-restricted, and an unresponsive
  # TPM-CRB device makes Server 2025 spin forever at early boot. Server 2025 needs
  # no TPM; OpenShift/KubeVirt can attach its own to the deployed VM if needed.
  vtpm = false

  headless         = true
  vnc_bind_address = "0.0.0.0"
  vnc_port_min     = 5910
  vnc_port_max     = 5910

  machine_type = "q35"
  cpu_model    = "host"
  cores        = var.cpus
  memory       = var.memory
  vga          = "qxl"

  floppy_files = ["answer_files/${var.os_name}-${var.os_version}-${var.os_arch}/Autounattend.xml"]

  disk_interface = "virtio-scsi"
  disk_size      = var.disk_size
  disk_discard   = "unmap"

  iso_url         = var.iso_url
  iso_checksum    = var.iso_checksum
  iso_target_path = local.iso_target_path

  qemuargs = concat(
    [
      ["-drive", "if=pflash,unit=0,file=${var.efi_firmware_code},format=qcow2,readonly=on"],
      ["-drive", "if=pflash,unit=1,file=${var.output_dir}/efivars.fd,format=qcow2"],
      ["-drive", "if=none,id=drive0,file=${var.output_dir}/${local.base_name},format=qcow2,cache=writeback,discard=unmap"],
      ["-drive", "media=cdrom,file=${local.iso_target_path}"],
      ["-drive", "media=cdrom,file=${var.local_libvirt_images}/virtio-win.iso"],
    ],
    var.capture_traffic ? [
      ["-object", "filter-dump,id=fd0,netdev=user.0,file=${var.output_dir}/traffic-base.pcap,maxlen=256"],
    ] : []
  )

  boot_wait    = "2s"
  # Spam a keypress across the whole "Press any key to boot from CD or DVD..." window.
  # A single keypress at a fixed boot_wait is timing-flaky: when OVMF POST runs slow
  # (host under I/O load) the key lands BEFORE the prompt, is discarded, and the VM
  # falls through to "No bootable device" and hangs until the 5h WinRM timeout. Pressing
  # enter repeatedly ~1s apart from ~2s..13s reliably hits the prompt regardless of POST
  # timing; extra presses are harmless (Autounattend.xml drives Setup unattended).
  boot_command = ["<enter><wait><enter><wait><enter><wait><enter><wait><enter><wait><enter><wait><enter><wait><enter><wait><enter><wait><enter><wait><enter>"]

  communicator   = "winrm"
  winrm_timeout  = "5h"
  winrm_username = var.winrm_username
  winrm_password = var.winrm_password

  # Non-generalized base: just shut down cleanly (no sysprep here).
  shutdown_command = "shutdown /s /t 10 /f /d p:4:1"
  shutdown_timeout = "30m"
}

build {
  name    = "base"
  sources = ["source.qemu.base"]

  # Clear the pending-reboot state left by Windows setup.
  provisioner "windows-restart" { restart_timeout = "30m" }
  provisioner "powershell" { inline = ["Write-Host '=== Reboot complete - building base image ==='"] }

  # Bake the latest cumulative update (offline .msu via DISM). Best-effort.
  # 4h timeout: DISM /Add-Package of the full ~2.4 GB cumulative does heavy
  # component-store I/O, which is slow on the /chungus raidz1 (spinning WD Greens) -
  # it blew a 2h timeout once. The curl download itself is fast (~38 MB/s); the time
  # is all DISM applying on slow storage.
  provisioner "powershell" {
    script  = "scripts/install-windows-updates.ps1"
    timeout = "4h"
  }
  provisioner "windows-restart" { restart_timeout = "1h" }

  # Now make the base deterministic: disable Windows Update + harden.
  provisioner "powershell" {
    script  = "scripts/disable-windows-update.ps1"
    timeout = "15m"
  }
  provisioner "powershell" {
    script  = "scripts/harden-build-server.ps1"
    timeout = "10m"
  }

  # Reboot to clear any pending-reboot/Windows-Installer-busy state left by the
  # cumulative update before the next MSI (PowerShell 7) - that state made the PS7
  # msiexec fail (exit ~16001) and abort the whole base build.
  provisioner "windows-restart" { restart_timeout = "1h" }

  # PowerShell 7 lives in the base (broadly useful).
  provisioner "powershell" {
    script  = "scripts/install-powershell.ps1"
    timeout = "30m"
  }
}
