# Building the images on an Ubuntu VM (incl. on OpenShift Virtualization)

These Packer builds just need **QEMU/KVM + Packer**, so they run on any Ubuntu
24.04/26.04 box with hardware virtualization - including an Ubuntu VM running on
OpenShift Virtualization (KubeVirt). The one thing that matters is **nested KVM**:
a Windows build under software emulation (TCG) would take days, so the builder VM
*must* have a working `/dev/kvm`.

## 0. The critical prerequisite: nested virtualization

Packer launches a QEMU/KVM VM *inside* your builder VM, so the builder VM needs
KVM. On bare metal / Proxmox that's automatic. On **KubeVirt** it requires:

1. **Node**: nested KVM enabled on the OpenShift worker (cluster-admin):
   `kvm_intel nested=1` / `kvm_amd nested=1` (set via MachineConfig / kernel arg).
2. **VM**: expose host CPU virtualization to the guest - in the VM spec:
   ```yaml
   spec:
     template:
       spec:
         domain:
           cpu:
             model: host-passthrough   # passes vmx/svm through to the guest
   ```
   (`host-passthrough` or a model that includes the `vmx`/`svm` feature.)

**Verify inside the Ubuntu builder VM before anything else:**
```bash
egrep -c '(vmx|svm)' /proc/cpuinfo   # must be > 0
ls -l /dev/kvm                        # must exist
sudo apt-get install -y cpu-checker && sudo kvm-ok   # "KVM acceleration can be used"
```
If `/dev/kvm` is missing, fix the node/VM nested-virt config first - everything
else will be uselessly slow otherwise.

## 1. Provision the Ubuntu builder VM (on OpenShift)

Size it generously - it hosts a 4 GB Windows build VM plus Packer, and the
outputs are ~35 GB each:
- **vCPU**: 6-8 (CPU `host-passthrough`)
- **RAM**: 12-16 GB
- **Disk**: 250 GB+ (ISOs ~8 GB, virtio ~1 GB, two qcow2 outputs ~35 GB each, pcaps)

A minimal KubeVirt VM (Ubuntu cloud image via a DataVolume) with `host-passthrough`
and a 250Gi rootdisk does the job; SSH in and continue.

## 2. Install the build tooling

```bash
sudo apt-get update
sudo apt-get install -y qemu-system-x86 qemu-utils ovmf tshark unzip curl jq
# Packer (HashiCorp apt repo)
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y packer
# allow your user to use kvm (re-login after)
sudo usermod -aG kvm "$USER"
```

## 3. Firmware, virtio drivers, ISO

Ubuntu ships OVMF as raw `.fd`; Packer's QEMU builder wants qcow2 (convert once):
```bash
mkdir -p ~/ovmf-qcow2
qemu-img convert -f raw -O qcow2 /usr/share/OVMF/OVMF_CODE_4M.secboot.fd ~/ovmf-qcow2/OVMF_CODE_4M.secboot.qcow2
qemu-img convert -f raw -O qcow2 /usr/share/OVMF/OVMF_VARS_4M.fd        ~/ovmf-qcow2/OVMF_VARS_4M.qcow2
```
(On 26.04 the file names may differ slightly - check `ls /usr/share/OVMF/`.)

virtio-win ISO + the Windows Server 2025 eval ISO (paths match `local_libvirt_images`,
default `/chungus/isos` - override `-var local_libvirt_images=...` to your dir):
```bash
ISO_DIR=~/isos && mkdir -p $ISO_DIR
curl -Lo $ISO_DIR/virtio-win.iso https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso
# Windows Server 2025 eval ISO -> $ISO_DIR/windows-server-2025.iso, then:
ln -sf $ISO_DIR/windows-server-2025.iso $ISO_DIR/windows-2025-x64.iso
```

## 4. Get the repo + init Packer

```bash
git clone <this-repo> && cd packer-qemu-win11
packer init .
```
Edit `os_pkrvars/windows-2025-x64.pkrvars.hcl` if your ISO path differs.

## 5. Build: base, then build-server

The build runners hardcode Proxmox paths; on Ubuntu pass the vars explicitly:
```bash
OVMF=~/ovmf-qcow2 ; ISO=~/isos ; OUT=~/packer-output ; GOLD=~/golden-images
mkdir -p $GOLD

# --- BASE (OS + updates + harden + PowerShell), ~2 h ---
packer build -only='base.*' \
  -var-file=os_pkrvars/windows-2025-x64.pkrvars.hcl \
  -var efi_firmware_code=$OVMF/OVMF_CODE_4M.secboot.qcow2 \
  -var efi_firmware_vars=$OVMF/OVMF_VARS_4M.qcow2 \
  -var local_libvirt_images=$ISO -var output_dir=$OUT .
# archive the base so the next stage can layer on it:
mv $OUT/windows-2025-x64-base $GOLD/windows-2025-base.qcow2
mv $OUT/efivars.fd            $GOLD/windows-2025-base-efivars.fd
scripts/extract-domains.sh $OUT/traffic-base.pcap > $GOLD/domains-base.txt
rm -rf $OUT

# --- BUILD-SERVER (VS + tools + agents + generalize), ~2 h ---
packer build -only='buildserver.*' \
  -var-file=os_pkrvars/windows-2025-x64.pkrvars.hcl \
  -var efi_firmware_code=$OVMF/OVMF_CODE_4M.secboot.qcow2 \
  -var local_libvirt_images=$ISO -var output_dir=$OUT \
  -var base_image=$GOLD/windows-2025-base.qcow2 \
  -var base_efivars=$GOLD/windows-2025-base-efivars.fd .
mv $OUT/windows-2025-x64-buildserver $GOLD/windows-server-2025-vs2026.qcow2
scripts/extract-domains.sh $OUT/traffic-buildserver.pcap > $GOLD/domains-buildserver.txt
```

## 6. Whitelist domains

`domains-base.txt` + `domains-buildserver.txt` are the full lists of hostnames the
builds reached (DNS + TLS SNI). Give them to your firewall/proxy team. Re-generated
every build, so they stay current.

## 7. Deploy

Upload `windows-server-2025-vs2026.qcow2` as a DataVolume/PVC and template it -
see **OPENSHIFT.md**. The base PVC can also be kept and cloned to build derived
images in-cluster later.

## Notes
- Building *on* KubeVirt needs nested virt (above). If that's not available, build
  on Proxmox / a bare-metal Ubuntu box and just import the qcow2 to OpenShift.
- No swtpm needed (vTPM is disabled in these builds).
- Same flow works for a non-OpenShift Ubuntu host - skip section 1's KubeVirt bits.
