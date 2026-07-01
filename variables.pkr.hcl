packer {
  required_version = ">= 1.15.1"
  required_plugins {
    qemu = {
      version = ">= 1.1.4"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

# --- OS identity (drives names + the answer-file path) ---
variable "os_name"    { type = string }
variable "os_version" { type = string }
variable "os_arch"    { type = string }

# --- WinRM build credentials (also the baked autologin/admin account) ---
variable "winrm_username" {
  type        = string
  description = "Username for WinRM connection"
}
variable "winrm_password" {
  type        = string
  sensitive   = true
  description = "Password for WinRM connection"
}

# --- EFI / firmware ---
variable "efi_firmware_code" {
  type    = string
  default = "/usr/share/edk2/ovmf/OVMF_CODE_4M.secboot.qcow2"
}
variable "efi_firmware_vars" {
  type    = string
  default = "/usr/share/edk2/ovmf/OVMF_VARS_4M.secboot.qcow2"
}

# --- Paths ---
variable "local_libvirt_images" {
  type    = string
  default = "/chungus/isos"
}
variable "output_dir" {
  type        = string
  default     = "/chungus/packer-output"
  description = "Per-build output directory (must not exist at build start)."
}
variable "iso_url"      { type = string }
variable "iso_checksum" { type = string }

# --- Layering: the BASE image the build-server stage builds on top of ---
variable "base_image" {
  type        = string
  default     = "/chungus/golden-images/windows-2025-base.qcow2"
  description = "Path to the base qcow2 (output of the 'base' build) that the 'buildserver' build layers on."
}
variable "base_efivars" {
  type        = string
  default     = "/chungus/golden-images/windows-2025-base-efivars.fd"
  description = "EFI vars from the base build (carries the Windows boot entry) - reused by the buildserver build."
}

# --- VM sizing (the host's RAM ceiling -> 4 GB) ---
# disk_size MUST be identical for base and buildserver: the buildserver disk is a
# qcow2 overlay on the base, and an overlay smaller than its backing file truncates
# the disk (cutting off the GPT backup header -> boot failure 0xc000000f). Shared
# here so the two sources can never drift.
variable "disk_size" {
  type    = string
  # 80G so deployed clones fit an 80Gi PVC (a clone can't be smaller than the
  # golden's virtual disk). The image currently uses ~41 GB, leaving ~39 GB for
  # the VS install peak at build time and CI work at runtime - tight but workable;
  # bump if the build ever runs out of space.
  default = "80G"
}
variable "cpus" {
  type    = number
  default = 4
}
variable "memory" {
  type    = number
  # 6 GB (top of the 4-6 GB build budget): extra page cache cuts the disk I/O
  # thrashing during the DISM cumulative-update apply on the slow /chungus raidz1.
  default = 6144
}

# --- Capture every domain the build talks to (for firewall whitelisting). ---
# Writes a truncated pcap of all VM traffic via QEMU's filter-dump; parse it with
# scripts/extract-domains.sh. maxlen keeps DNS queries + TLS SNI but not bulk data.
variable "capture_traffic" {
  type    = bool
  default = true
}

locals {
  base_name        = "${var.os_name}-${var.os_version}-${var.os_arch}-base"
  buildserver_name = "${var.os_name}-${var.os_version}-${var.os_arch}-buildserver"
  iso_target_path  = "${var.local_libvirt_images}/${var.os_name}-${var.os_version}-${var.os_arch}.iso"
}
