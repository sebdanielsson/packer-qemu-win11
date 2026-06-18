#!/usr/bin/env bash
# Kill the hung packer build (SIGKILL -> no packer cleanup, so output disk survives),
# then boot an overlay of the installed disk WITHOUT a TPM to test the vTPM-spin theory.
set -x
pkill -9 -f "packer build"; pkill -9 -f "build-2025.sh"; sleep 1
pkill -9 -f "qemu-system-x86_64.*windows-2025-x64"; sleep 2
echo "=== output dir after kill (disk should survive) ==="
ls -la /chungus/packer-output/
[ -f /chungus/packer-output/windows-2025-x64 ] || { echo "DISK GONE — packer cleaned up"; exit 1; }
mkdir -p /chungus/tmp
cp -f /chungus/packer-output/efivars.fd /chungus/tmp/testA-efivars.fd
rm -f /chungus/tmp/testA.qcow2
qemu-img create -f qcow2 -b /chungus/packer-output/windows-2025-x64 -F qcow2 /chungus/tmp/testA.qcow2
qemu-system-x86_64 -machine q35,accel=kvm -m 4096 -smp 4,cores=4 -cpu host \
  -drive if=pflash,unit=0,file=/root/ovmf-qcow2/OVMF_CODE_4M.secboot.qcow2,format=qcow2,readonly=on \
  -drive if=pflash,unit=1,file=/chungus/tmp/testA-efivars.fd,format=qcow2 \
  -device virtio-scsi-pci,id=scsi0 -device scsi-hd,bus=scsi0.0,drive=drive0 \
  -drive if=none,id=drive0,file=/chungus/tmp/testA.qcow2,format=qcow2,cache=writeback \
  -netdev user,id=u -device virtio-net,netdev=u \
  -vga qxl -vnc 0.0.0.0:11 -daemonize -name testA-notpm
sleep 2
echo "=== testA qemu running? ==="
pgrep -af "testA-notpm"
