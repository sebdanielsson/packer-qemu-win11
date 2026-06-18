#!/usr/bin/env bash
# Run the Windows Server 2025 packer build on the Proxmox host (as root).
# Logs to /chungus/packer-2025-build.log and records the packer exit code.
set -o pipefail
cd /root/packer-qemu-win11
PACKER_LOG=1 packer build \
  -var-file=os_pkrvars/windows-2025-x64.pkrvars.hcl \
  -var efi_firmware_code=/root/ovmf-qcow2/OVMF_CODE_4M.secboot.qcow2 \
  -var efi_firmware_vars=/root/ovmf-qcow2/OVMF_VARS_4M.qcow2 \
  . 2>&1 | tee /chungus/packer-2025-build.log
echo "PACKER_EXIT=${PIPESTATUS[0]}" | tee -a /chungus/packer-2025-build.log
