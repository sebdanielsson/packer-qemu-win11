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
OUT="${OUTPUT_DIR:-/chungus/packer-output}"
PACKER_LOG=1 packer build -only='buildserver.*' -on-error=abort \
  -var-file=os_pkrvars/windows-2025-x64.pkrvars.hcl \
  -var efi_firmware_code=/root/ovmf-qcow2/OVMF_CODE_4M.secboot.qcow2 \
  -var "base_image=${BASE_IMG}" \
  -var "base_efivars=${BASE_EFI}" \
  -var "output_dir=${OUT}" \
  . 2>&1 | tee /chungus/packer-buildserver-build.log
RC=${PIPESTATUS[0]}
echo "PACKER_EXIT=${RC}" | tee -a /chungus/packer-buildserver-build.log

# The buildserver source uses use_backing_file=true, so packer's artifact is a thin
# qcow2 OVERLAY on the base - NOT deployable on its own (KubeVirt/a DataVolume needs
# a self-contained disk, and the overlay also breaks if the base is moved/rebuilt).
# Flatten it: qemu-img convert reads through the backing chain and writes a single
# standalone qcow2. That file is the real deliverable to upload to OpenShift.
if [ "${RC}" -eq 0 ] && [ -f "${OUT}/windows-2025-x64-buildserver" ]; then
  echo "=== Flattening overlay -> standalone deployable qcow2 ===" | tee -a /chungus/packer-buildserver-build.log
  qemu-img convert -O qcow2 "${OUT}/windows-2025-x64-buildserver" \
    "${OUT}/windows-server-2025-vs2026.qcow2" \
    && echo "Standalone deliverable: ${OUT}/windows-server-2025-vs2026.qcow2" | tee -a /chungus/packer-buildserver-build.log \
    || echo "WARNING: flatten failed; the overlay still needs its base." | tee -a /chungus/packer-buildserver-build.log
fi
