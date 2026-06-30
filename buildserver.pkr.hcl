# BUILD-SERVER image: layers on the BASE (var.base_image) and adds VS 2026,
# .NET, mise, Chrome, and both CI agents, then generalizes into a deployable
# template. Requires the base build to have run first. Build with:
#   packer build -only='buildserver.*' -var base_image=/path/to/base.qcow2 ...
source "qemu" "buildserver" {
  vm_name          = local.buildserver_name
  output_directory = var.output_dir

  efi_boot          = true
  efi_firmware_code = var.efi_firmware_code
  efi_firmware_vars = var.base_efivars   # carries the base's Windows boot entry

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

  # Start from the base disk instead of an ISO. use_backing_file makes the output
  # a thin overlay on the base (instant; no 35 GB copy on the slow store) - packer
  # compacts it to a standalone qcow2 at the end ("Converting hard drive").
  disk_image       = true
  use_backing_file = true
  iso_url          = var.base_image
  iso_checksum     = "none"
  disk_interface   = "virtio-scsi"
  # MUST match the base's disk_size: a smaller overlay truncates the backing disk
  # and corrupts the GPT -> boot failure 0xc000000f. Shared var keeps them in lockstep.
  disk_size        = var.disk_size
  disk_discard     = "unmap"

  qemuargs = concat(
    [
      ["-drive", "if=pflash,unit=0,file=${var.efi_firmware_code},format=qcow2,readonly=on"],
      ["-drive", "if=pflash,unit=1,file=${var.output_dir}/efivars.fd,format=qcow2"],
      ["-drive", "if=none,id=drive0,file=${var.output_dir}/${local.buildserver_name},format=qcow2,cache=writeback,discard=unmap"],
    ],
    var.capture_traffic ? [
      ["-object", "filter-dump,id=fd0,netdev=user.0,file=${var.output_dir}/traffic-buildserver.pcap,maxlen=256"],
    ] : []
  )

  communicator   = "winrm"
  winrm_timeout  = "1h"
  winrm_username = var.winrm_username
  winrm_password = var.winrm_password

  # Always generalize the build-server into a reusable template.
  shutdown_command = "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\sysprep-generalize.ps1"
  shutdown_timeout = "30m"
}

build {
  name    = "buildserver"
  sources = ["source.qemu.buildserver"]

  provisioner "windows-restart" { restart_timeout = "30m" }
  provisioner "powershell" { inline = ["Write-Host '=== Base booted - installing build-server tooling ==='"] }

  # Visual Studio Professional 2026 + .NET 10 SDK.
  # 6h timeout: VS does heavy small-file I/O into the qcow2 on the /chungus raidz1
  # (spinning WD Greens). It normally finishes in ~1.5h, but under host I/O
  # contention it once crawled past a 4h timeout and got cancelled mid-install.
  provisioner "powershell" {
    script  = "scripts/install-visual-studio.ps1"
    timeout = "6h"
  }

  # VS leaves a pending-reboot/Windows-Installer-busy state; reboot before the next
  # MSI (Chrome) or its msiexec blocks forever on the _MSIExecute mutex (this hung
  # install-dev-tools for the full provisioner timeout and errored the build).
  provisioner "windows-restart" { restart_timeout = "30m" }

  # Extra dev tooling: mise + latest stable Google Chrome.
  provisioner "powershell" {
    script  = "scripts/install-dev-tools.ps1"
    timeout = "60m"
  }

  # QEMU guest agent (virtio-win guest tools) so OpenShift/KubeVirt gets guest
  # integration (reported IP/OS, graceful shutdown, snapshot quiesce).
  provisioner "powershell" {
    script  = "scripts/install-qemu-guest-agent.ps1"
    timeout = "30m"
  }

  # cloudbase-init so deployed VMs self-configure at first boot from a KubeVirt
  # cloudInitConfigDrive / Proxmox cloud-init drive (proxy/CA + agent enrollment).
  provisioner "powershell" {
    script  = "scripts/install-cloudbase-init.ps1"
    timeout = "30m"
  }

  # Bundle (but do not configure) BOTH CI agents - the choice is made at
  # provision/boot time by whichever enroll script runs.
  provisioner "powershell" {
    script  = "scripts/install-azure-pipelines-agent.ps1"
    timeout = "60m"
  }
  provisioner "powershell" {
    script  = "scripts/install-github-runner.ps1"
    timeout = "60m"
  }

  # Stage the sysprep helpers. Enrollment is done at deploy time with the runners'
  # own scripts (config.cmd/run.cmd/svc.cmd) directly - no wrapper is baked in.
  provisioner "file" {
    source      = "answer_files/windows-2025-x64/sysprep-unattend.xml"
    destination = "C:\\sysprep-unattend.xml"
  }
  provisioner "file" {
    source      = "scripts/sysprep-generalize.ps1"
    destination = "C:\\sysprep-generalize.ps1"
  }
}
