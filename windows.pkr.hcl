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
  default = "windows"
}
variable "os_version" {
  type = string
  default = "11"
}
variable "os_arch" {
  type = string
  default = "x64"
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
  default = "https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/26100.1742.240906-0331.ge_release_svc_refresh_CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso"
}
variable "iso_checksum" {
  type = string
  default = "755A90D43E826A74B9E1932A34788B898E028272439B777E5593DEE8D53622AE"
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

  disk_interface = "virtio-scsi"
  disk_size = "60G"
  disk_discard = "unmap"

  iso_url = "${var.iso_url}"
  iso_checksum = "${var.iso_checksum}"
  iso_target_path = "${local.iso_target_path}"

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
