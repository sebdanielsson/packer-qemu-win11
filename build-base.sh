#!/usr/bin/env bash
# Build the BASE image (OS + updates + harden + PowerShell), on the Proxmox host.
# Output: $output_dir/<os>-<ver>-<arch>-base  (+ efivars.fd, traffic-base.pcap)
set -o pipefail
cd "$(dirname "$0")"
# -on-error=abort keeps the output on failure so a late-stage error (e.g. after the
# ~2 h cumulative-update DISM apply) doesn't throw the whole build away - the disk
# can be inspected/salvaged. Clean /chungus/packer-output before a retry.
PACKER_LOG=1 packer build -only='base.*' -on-error=abort \
  -var-file=os_pkrvars/windows-2025-x64.pkrvars.hcl \
  -var efi_firmware_code=/root/ovmf-qcow2/OVMF_CODE_4M.secboot.qcow2 \
  -var efi_firmware_vars=/root/ovmf-qcow2/OVMF_VARS_4M.qcow2 \
  . 2>&1 | tee /chungus/packer-base-build.log
echo "PACKER_EXIT=${PIPESTATUS[0]}" | tee -a /chungus/packer-base-build.log
