#!/usr/bin/env bash
# Verify the finished golden image boots cleanly (no OOBE/language prompt) as a
# fresh "deployment": archive it, then boot a throwaway overlay with NO TPM
# (the host's swtpm is broken) on VNC :12 (port 5912).
set -e
OUT=/chungus/packer-output
GOLD=/chungus/golden-images
STAMP_NAME=windows-server-2025-vs2026
[ -f "$OUT/windows-2025-x64" ] || { echo "NO OUTPUT DISK"; exit 1; }

echo "=== archiving golden image ==="
cp -f "$OUT/windows-2025-x64"  "$GOLD/$STAMP_NAME.qcow2"
cp -f "$OUT/efivars.fd"        "$GOLD/$STAMP_NAME-efivars.fd"
ls -la "$GOLD/$STAMP_NAME.qcow2" "$GOLD/$STAMP_NAME-efivars.fd"

echo "=== creating throwaway overlay + efivars copy ==="
mkdir -p /chungus/tmp
rm -f /chungus/tmp/verify.qcow2
cp -f "$OUT/efivars.fd" /chungus/tmp/verify-efivars.fd
qemu-img create -f qcow2 -b "$GOLD/$STAMP_NAME.qcow2" -F qcow2 /chungus/tmp/verify.qcow2

echo "=== booting verify VM (no TPM) on VNC :12 ==="
pkill -9 -f "verify-2025" 2>/dev/null || true
qemu-system-x86_64 -machine q35,accel=kvm -m 4096 -smp 4,cores=4 -cpu host \
  -drive if=pflash,unit=0,file=/root/ovmf-qcow2/OVMF_CODE_4M.secboot.qcow2,format=qcow2,readonly=on \
  -drive if=pflash,unit=1,file=/chungus/tmp/verify-efivars.fd,format=qcow2 \
  -device virtio-scsi-pci,id=scsi0 -device scsi-hd,bus=scsi0.0,drive=drive0 \
  -drive if=none,id=drive0,file=/chungus/tmp/verify.qcow2,format=qcow2,cache=writeback \
  -netdev user,id=u -device virtio-net,netdev=u \
  -vga qxl -vnc 0.0.0.0:12 -daemonize -name verify-2025
sleep 2
pgrep -af "verify-2025" >/dev/null && echo "verify VM started on 5912" || echo "FAILED TO START"
