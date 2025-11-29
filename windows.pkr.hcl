packer {
  required_version = ">= 1.7.0"
  required_plugins {
    qemu = {
      version = ">= 1.0.7"
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

variable "efi_boot" {
  type = bool
  default = true
}
variable "efi_firmware_code" {
  type = string
  default = "/usr/share/edk2/ovmf/OVMF_CODE.secboot.fd"
}
variable "efi_firmware_vars" {
  type = string
  default = "/usr/share/edk2/ovmf/OVMF_VARS.secboot.fd"
}

variable "local_libvirt_images" {
  type = string
  default = "${ env("HOME") }/.local/share/libvirt/images"
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
  vm_name = "${var.os_name}-${var.os_version}-${var.os_arch}"

  efi_boot = "${var.efi_boot}"
  efi_firmware_code = "${var.efi_firmware_code}"
  efi_firmware_vars = "${var.efi_firmware_vars}"

  vtpm = true
  tpm_device_type = "tpm-crb"

  machine_type = "q35"
  cpu_model = "host"
  cores = 4
  memory = 8192
  vga = "qxl"

  floppy_files = var.os_name == "windows" ? [
    "answer_files/${var.os_name}-${var.os_version}-${var.os_arch}/Autounattend.xml"
  ] : []

  disk_interface = "virtio-scsi"
  disk_size = "60G"
  disk_discard = "unmap"

  iso_url = "${var.iso_url}"
  iso_checksum = "${var.iso_checksum}"
  iso_target_path = "${local.iso_target_path}"

  qemuargs = concat(
    var.efi_boot ? [
      ["-drive", "if=pflash,unit=0,file=${var.efi_firmware_code},format=raw,readonly=on"],
      ["-drive", "if=pflash,unit=1,file=output-vm/efivars.fd,format=raw"],
    ] : [],
    [
      ["-drive", "if=none,id=drive0,file=output-vm/${var.os_name}-${var.os_version}-${var.os_arch},format=qcow2,cache=writeback,discard=unmap"],
      ["-drive", "media=cdrom,file=${local.iso_target_path}"],
      ["-drive", "media=cdrom,file=${var.local_libvirt_images}/virtio-win.iso"],
    ]
  )

  boot_wait = "1s"
  boot_command = [
    "<enter>"
  ]

  communicator = "winrm"
  winrm_timeout = "1h30m"
  winrm_username = "vagrant"
  winrm_password = "vagrant"
}

build {
  sources = [
    "source.qemu.vm"
  ]
}
