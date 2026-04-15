# Building the Windows 11 Golden Image on Proxmox

This guide covers how to build the Windows 11 QCOW2 golden image by running
Packer directly on the Proxmox host. This is the recommended approach because:

- Proxmox ships `pve-edk2-firmware` which includes the required 4M OVMF files
- Native KVM acceleration is available (no nested virtualisation overhead)
- Packer, QEMU, and swtpm are already installed on Proxmox

Tested on: **Proxmox VE 9.1.6**, Packer 1.15.1, QEMU 10.1.2, swtpm 0.8.0

## Prerequisites

Everything below runs as `root` on the Proxmox host.

### 1. Verify required tools are present

```bash
packer version          # Packer v1.15.1 or later
qemu-img --version      # part of pve-qemu-kvm
swtpm --version         # part of swtpm
ls /usr/share/pve-edk2-firmware/OVMF_CODE_4M.secboot.fd
ls /usr/share/pve-edk2-firmware/OVMF_VARS_4M.fd
```

If `packer` is missing, download the binary directly from HashiCorp (the
apt/rpm repos may not have a package for your Proxmox version):

```bash
PACKER_URL=$(curl -s https://api.releases.hashicorp.com/v1/releases/packer/latest \
  | python3 -c "import sys,json; r=json.load(sys.stdin); \
    print(next(b['url'] for b in r['builds'] if b['os']=='linux' and b['arch']=='amd64'))")
curl -Lo /tmp/packer.zip "$PACKER_URL"
unzip -o /tmp/packer.zip -d /usr/local/bin/
chmod +x /usr/local/bin/packer
```

### 2. Convert OVMF firmware files from raw to QCOW2

Packer's QEMU builder requires the EFI firmware files in QCOW2 format.
Proxmox ships them as raw `.fd` files, so convert them once:

```bash
mkdir -p /root/ovmf-qcow2
qemu-img convert -f raw -O qcow2 \
  /usr/share/pve-edk2-firmware/OVMF_CODE_4M.secboot.fd \
  /root/ovmf-qcow2/OVMF_CODE_4M.secboot.qcow2
qemu-img convert -f raw -O qcow2 \
  /usr/share/pve-edk2-firmware/OVMF_VARS_4M.fd \
  /root/ovmf-qcow2/OVMF_VARS_4M.qcow2
```

### 3. Download the virtio-win ISO

Packer does not fetch this automatically — it must be present before the build:

```bash
mkdir -p /root/.local/share/libvirt/images
curl -L -o /root/.local/share/libvirt/images/virtio-win.iso \
  https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso
```

### 4. Install the Packer QEMU plugin

Run this once inside the repo directory:

```bash
cd /root/packer-qemu-win11
packer init .
```

## Running the Build

### 5. Start the build in a tmux session

The build takes roughly 20–30 minutes with native KVM. Run it inside `tmux` so
it survives SSH disconnects:

```bash
tmux new-session -s packer-build
cd /root/packer-qemu-win11
PACKER_LOG=1 packer build \
  -var-file=os_pkrvars/windows-11-x64.pkrvars.hcl \
  -var efi_firmware_code=/root/ovmf-qcow2/OVMF_CODE_4M.secboot.qcow2 \
  -var efi_firmware_vars=/root/ovmf-qcow2/OVMF_VARS_4M.qcow2 \
  . 2>&1 | tee /root/packer-build.log
```

To detach from tmux while the build runs: `Ctrl-B` then `D`.  
To reattach later: `tmux attach -t packer-build`

### 6. Watch progress via VNC (optional)

The build config exposes VNC on port 5910. Connect from any VNC client:

```plaintext
192.168.1.100:5910   (no password)
```

You should see the UEFI boot picker briefly, then the Windows installer loading
automatically. The `boot_command` sends `<down><enter>` after 3 seconds to
select the DVD-ROM from the UEFI boot menu.

### 7. Wait for completion

Packer will:

1. Download the Windows 11 ISO (~5 GB, skipped if already cached)
2. Boot Windows in QEMU with the `Autounattend.xml` floppy injected
3. Windows installs unattended, installs virtio drivers, creates the `builder` user
4. On first logon, WinRM is configured automatically
5. Packer connects via WinRM, gracefully shuts down the VM
6. `qemu-img convert` compacts the output disk

Output: `output-vm/windows-11-x64` (QCOW2, ~9 GB)

## Backing Up and Creating a Proxmox VM

### 8. Back up the golden image

```bash
mkdir -p /chungus/golden-images
cp /root/packer-qemu-win11/output-vm/windows-11-x64 \
   /chungus/golden-images/windows-11-x64.qcow2
cp /root/packer-qemu-win11/output-vm/efivars.fd \
   /chungus/golden-images/windows-11-x64-efivars.fd
```

### 9. Create a Proxmox VM and import the disk

```bash
# Create the VM (adjust VMID and storage pool as needed)
qm create 201 \
  --name windows-11-golden-test \
  --machine q35 \
  --bios ovmf \
  --tpmstate chungus:4,version=v2.0 \
  --cpu host \
  --cores 4 \
  --memory 12288 \
  --net0 virtio,bridge=vmbr0 \
  --ostype win11 \
  --vga qxl \
  --efidisk0 chungus:0,efitype=4m,pre-enrolled-keys=1 \
  --scsihw virtio-scsi-pci

# Import the disk (ZFS converts qcow2 → raw automatically)
qm importdisk 201 /chungus/golden-images/windows-11-x64.qcow2 chungus --format qcow2

# Attach the imported disk and set boot order
qm set 201 --scsi0 chungus:vm-201-disk-2,discard=on
qm set 201 --boot order=scsi0

# Start the VM
qm start 201
```

> **Note:** `qm importdisk` prints the disk name (e.g. `vm-201-disk-2`) at the
> end of its output — use that exact name in the `qm set` command above.

Open **Proxmox UI → VM 201 → Console** to watch Windows boot. On first start it
will do a brief hardware detection pass, then boot straight to the desktop.

## Troubleshooting

### VS installer exit code 267014

Exit code 267014 from the VS bootstrapper inside a packer build is caused by
**Windows Task Scheduler terminating the process**. Packer's `elevated_user` /
`elevated_password` provisioner option wraps scripts in a scheduled task, which
has its own execution timeout and can kill long-running processes like the VS
installer (~90 min). See:
https://learn.microsoft.com/en-us/answers/questions/4257963/task-scheduler-error-267014-process-terminated-by

**Fix:** do not use `elevated_user` / `elevated_password` on the VS provisioner.
Running the script directly via WinRM as `builder` (a local admin) is sufficient
and avoids the scheduled task wrapper entirely. Also use `--quiet` instead of
`--passive` since WinRM sessions are non-interactive (no desktop/window station).

A pending-reboot state left by the initial Windows setup can also cause the VS
installer to abort early. A `windows-restart` provisioner before the VS step
clears this reliably.

**Note on Windows Update:** `PSWindowsUpdate` (and the WUA COM API in general)
returns `E_ACCESSDENIED` when called from a non-interactive WinRM session. Windows
Update must be run from an interactive user session or via a Task Scheduler job
with the `/IT` (interactive) flag. For golden image builds, running Windows Update
post-deployment is simpler.

## Key Configuration Notes

| Setting | Value | Reason |
| ------- | ----- | ------ |
| `boot_wait` | `3s` | OVMF's boot picker auto-selects after ~5 s; keys must arrive before that |
| `boot_command` | `<down><enter>` | Moves from "EFI Firmware Setup" (default highlight) down to the DVD-ROM entry |
| `headless` | `true` | No display server on the host; VNC is used instead |
| `vnc_bind_address` | `0.0.0.0` | Allows connecting from outside the host |
| `vnc_port_min/max` | `5910` | Fixed port for easy access |
| `memory` | `12288` | 16 GB recommended for VS install; 8 GB minimum |
| `efi_firmware_code` | `/root/ovmf-qcow2/OVMF_CODE_4M.secboot.qcow2` | Proxmox ships raw `.fd`; must be converted to QCOW2 |
| `efi_firmware_vars` | `/root/ovmf-qcow2/OVMF_VARS_4M.qcow2` | Same as above |
