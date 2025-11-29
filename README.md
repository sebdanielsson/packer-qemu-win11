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

We know we'll need drivers for the paravirtualized virtio hardware, so we need
to inject the virtio-win.iso. And the way do that is by adding it as a `-drive`
parameter to `qemuargs` [1], but... adding a `-drive` or `-device` override
will mean that none of the default configuration Packer sets will be used. So
let's first insert the defaults from the log output and verify everything still
works.

```hcl
  qemuargs = concat(
    var.efi_boot ? [
      ["-drive", "if=pflash,unit=0,file=${var.efi_firmware_code},format=raw,readonly=on"],
      ["-drive", "if=pflash,unit=1,file=output-vm/efivars.fd,format=raw"],
    ] : [],
    [
      ["-drive", "if=none,id=drive0,file=output-vm/${var.os_name}-${var.os_version}-${var.os_arch},format=qcow2,cache=writeback,discard=unmap"],
      ["-drive", "media=cdrom,file=${local.iso_target_path}"],
    ]
  )
```

I'm putting the `efi_firmware_{code,vars}` inside a conditional block so
they're only included when `efi_boot` is `true`. Also worth noting, the
`efi_firmware_vars` is a template, and is copied out as `efivars.fd` to live
beside the main vm image.

# Build

```shell
PACKER_LOG=1 packer init windows.pkr.hcl
TMPDIR=$(pwd)/tmp PACKER_LOG=1 packer build -var-file os_pkrvars/windows-11-x64.pkrvars.hcl windows.pkr.hcl
```

[1] https://developer.hashicorp.com/packer/integrations/hashicorp/qemu/latest/components/builder/qemu#qemu-specific-configuration-reference
