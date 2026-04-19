packer {
  required_version = ">= 1.15.1"
  required_plugins {
    qemu = {
      version = ">= 1.1.4"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

variable "os_name" {
  type = string
}
variable "os_version" {
  type = string
}
variable "os_arch" {
  type = string
}

variable "winrm_username" {
  type = string
  description = "Username for WinRM connection"
}
variable "winrm_password" {
  type = string
  sensitive = true
  description = "Password for WinRM connection"
}

variable "efi_boot" {
  type = bool
  default = true
}
variable "efi_firmware_code" {
  type = string
  default = "/usr/share/edk2/ovmf/OVMF_CODE_4M.secboot.qcow2"
}
variable "efi_firmware_vars" {
  type = string
  default = "/usr/share/edk2/ovmf/OVMF_VARS_4M.secboot.qcow2"
}

variable "local_libvirt_images" {
  type = string
  default = "/chungus/isos"
}
variable "output_dir" {
  type = string
  default = "/chungus/packer-output"
}
variable "iso_url" {
  type = string
}
variable "iso_checksum" {
  type = string
}

locals {
  iso_target_path = "${var.local_libvirt_images}/${var.os_name}-${var.os_version}-${var.os_arch}.iso"
}

source "qemu" "vm" {
  vm_name          = "${var.os_name}-${var.os_version}-${var.os_arch}"
  output_directory = "${var.output_dir}"

  efi_boot = "${var.efi_boot}"
  efi_firmware_code = "${var.efi_firmware_code}"
  efi_firmware_vars = "${var.efi_firmware_vars}"

  vtpm = true
  tpm_device_type = "tpm-crb"

  headless = true
  vnc_bind_address = "0.0.0.0"
  vnc_port_min = 5910
  vnc_port_max = 5910

  machine_type = "q35"
  cpu_model = "host"
  cores = 4
  memory = 8192
  vga = "qxl"

  floppy_files = var.os_name == "windows" ? [
    "answer_files/${var.os_name}-${var.os_version}-${var.os_arch}/Autounattend.xml"
  ] : []

  disk_interface = "virtio-scsi"
  disk_size = "128G"
  disk_discard = "unmap"

  iso_url = "${var.iso_url}"
  iso_checksum = "${var.iso_checksum}"
  iso_target_path = "${local.iso_target_path}"

  qemuargs = concat(
    var.efi_boot ? [
      ["-drive", "if=pflash,unit=0,file=${var.efi_firmware_code},format=qcow2,readonly=on"],
      ["-drive", "if=pflash,unit=1,file=${var.output_dir}/efivars.fd,format=qcow2"],
    ] : [],
    [
      ["-drive", "if=none,id=drive0,file=${var.output_dir}/${var.os_name}-${var.os_version}-${var.os_arch},format=qcow2,cache=writeback,discard=unmap"],
      ["-drive", "media=cdrom,file=${local.iso_target_path}"],
      ["-drive", "media=cdrom,file=${var.local_libvirt_images}/virtio-win.iso"],
    ]
  )

  boot_wait = "3s"
  boot_command = [
    "<down><enter>"
  ]

  communicator = "winrm"
  winrm_timeout = "5h"
  winrm_username = var.winrm_username
  winrm_password = var.winrm_password
}

build {
  sources = [
    "source.qemu.vm"
  ]

  # Reboot before VS install to clear any pending-reboot state left by Windows
  # setup. VS installer exits 267014 if a reboot is still pending.
  # Note: Windows Update via PSWindowsUpdate fails with E_ACCESSDENIED in a
  # non-interactive WinRM session (WUA API restriction), so we skip it here.
  provisioner "windows-restart" {
    restart_timeout = "30m"
  }

  provisioner "powershell" {
    inline  = ["Write-Host '=== Reboot complete — proceeding to install Visual Studio ==='"]
  }

  provisioner "powershell" {
    script  = "scripts/install-visual-studio.ps1"
    timeout = "4h"
  }
}
