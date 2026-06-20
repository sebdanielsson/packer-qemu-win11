#!/usr/bin/env bash
# Build the BUILD-SERVER image on top of an existing BASE image, on the Proxmox host.
# Pass the base qcow2 + efivars (defaults point at /chungus/golden-images).
#   ./build-buildserver.sh [base.qcow2] [base-efivars.fd]
set -o pipefail
cd "$(dirname "$0")"
BASE_IMG="${1:-/chungus/golden-images/windows-2025-base.qcow2}"
BASE_EFI="${2:-/chungus/golden-images/windows-2025-base-efivars.fd}"
# -on-error=abort keeps the output overlay on failure (instead of deleting it), so
# a late-stage failure doesn't throw away the ~1.5 h Visual Studio install - the
# overlay can be inspected or salvaged. Clean /chungus/packer-output before a retry.
PACKER_LOG=1 packer build -only='buildserver.*' -on-error=abort \
  -var-file=os_pkrvars/windows-2025-x64.pkrvars.hcl \
  -var efi_firmware_code=/root/ovmf-qcow2/OVMF_CODE_4M.secboot.qcow2 \
  -var "base_image=${BASE_IMG}" \
  -var "base_efivars=${BASE_EFI}" \
  . 2>&1 | tee /chungus/packer-buildserver-build.log
echo "PACKER_EXIT=${PIPESTATUS[0]}" | tee -a /chungus/packer-buildserver-build.log
