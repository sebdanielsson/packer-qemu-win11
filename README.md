# Windows 11 on qemu

Windows 11 requires UEFI, TPM2 (crb) and probably PCIe (q35)?

So the idea here is to make qemu emulate as "modern" and performant hardware
as we can.

```hcl
  efi_boot = true
  vtpm = true
  tpm_device_type = "tpm-crb"
  machine_type = "q35"
  cpu_model = "host"
  disk_interface = "virtio-scsi"
  disk_discard = "unmap"
```

With this initial configuration starting the build with `PACKER_LOG=1` we'll get something like this;

```
Executing /usr/bin/qemu-system-x86_64: []string{
  "-machine", "type=q35,accel=kvm",
  "-vnc", "127.0.0.1:95",
  "-m", "8192M", "-smp", "4,cores=4", "-vga", "qxl", "-display", "gtk",
  "-tpmdev", "emulator,id=tpm0,chardev=vtpm",
  "-cpu", "host",
  "-device", "virtio-scsi-pci,id=scsi0",
  "-device", "scsi-hd,bus=scsi0.0,drive=drive0",
  "-device", "virtio-net,netdev=user.0",
  "-device", "tpm-crb,tpmdev=tpm0",
  "-netdev", "user,id=user.0,hostfwd=tcp::3452-:5985",
  "-name", "windows-11-x64",
  "-chardev", "socket,id=vtpm,path=/tmp/897791090/vtpm.sock",
  "-drive", "if=none,file=output-vm/windows-11-x64,id=drive0,cache=writeback,discard=unmap,format=qcow2",
  "-drive", "file=/home/eb4x/.local/share/libvirt/images/windows-11-x64.iso,media=cdrom",
  "-drive", "file=/usr/share/edk2/ovmf/OVMF_CODE.secboot.fd,if=pflash,unit=0,format=raw,readonly=on",
  "-drive", "file=output-vm/efivars.fd,if=pflash,unit=1,format=raw"
}
```

# Build

```shell
PACKER_LOG=1 packer init windows.pkr.hcl
TMPDIR=$(pwd)/tmp PACKER_LOG=1 packer build windows.pkr.hcl
```
