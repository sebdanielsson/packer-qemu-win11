# Deploying the Server 2025 image on OpenShift Virtualization via GitOps

A runbook for the **deploy end** (the repo that already has kustomize + ArgoCD).
It takes the golden image from Backblaze B2 into OpenShift Virtualization
(KubeVirt / OpenShift CNV) and runs it as GitOps-managed Windows VMs.

This is the GitOps companion to `OPENSHIFT.md` (imperative `virtctl` flow) and
`RUNTIME-CONFIG.md` (certs/proxy inside the guest). Read this end-to-end first —
there are two import strategies and the choice shapes the whole layout.

## TL;DR of the decisions

- **The 38.7 GB qcow2 does NOT go in git.** GitOps manages the *manifests*; the
  binary is seeded into the cluster separately (Path A) or pulled by CDI at apply
  time (Path B). Pick one in §3.
- **The Packer `-efivars.fd` is NOT used by KubeVirt.** KubeVirt generates its own
  EFI NVRAM per VM. Download it for completeness but don't try to mount it. Just
  enable EFI on the VM (§5).
- **Boot identity is already handled.** The image is generalized with a baked OOBE
  answer file, so a bare boot gets a unique hostname/SID (verified:
  `BUILDER-Q88BKSR`). A KubeVirt `sysprep` volume is only needed to inject
  per-instance config like agent enrollment (§6 + `OPENSHIFT.md` §4).

## 0. The artifact in B2

| | |
| --- | --- |
| S3 endpoint | `s3.us-west-001.backblazeb2.com` |
| Region | `us-west-001` |
| Bucket | `vm-images-sebdanielsson` (private) |
| Image object | `windows-server-2025-vs2026.qcow2` — 41,576,628,224 B (38.7 GiB, 128 GiB virtual) |
| EFI vars object | `windows-server-2025-vs2026-efivars.fd` — 917,504 B (not used by KubeVirt, see TL;DR) |

The qcow2 is a generalized Windows Server 2025 template: VS 2026 (18.7.1), .NET 10
(10.0.301), PowerShell 7.6.3, mise (shims on PATH), Chrome, Azure Pipelines agent
+ GitHub Actions runner (both unconfigured), qemu-guest-agent (virtio-win) and
cloudbase-init for KubeVirt integration, Developer Mode + Unrestricted execution
policy, Windows Update disabled, patched to build 26100.32995.

Credentials: a B2 application key with access to that bucket. The keyID looks like
`00160df9…` and the application key is the secret. **Supply your current key** —
the one used during the build was rotated. B2's keyID/appKey double as S3
`accessKeyId`/`secretAccessKey` against the S3 endpoint above.

## 1. Download from B2

Set the key in the environment so it never lands in a config file or shell history:

```bash
export B2_KEY_ID='<your-keyID>'
export B2_APP_KEY='<your-application-key>'
```

### Option A — rclone (recommended; resumable, multipart)

Uses an **ephemeral** remote defined entirely via env vars, so nothing is written
to `~/.config/rclone/rclone.conf`:

```bash
export RCLONE_CONFIG_B2_TYPE=b2
export RCLONE_CONFIG_B2_ACCOUNT="$B2_KEY_ID"
export RCLONE_CONFIG_B2_KEY="$B2_APP_KEY"

rclone copy b2:vm-images-sebdanielsson ./ \
  --include "windows-server-2025-vs2026*" \
  --b2-chunk-size 100M --b2-upload-concurrency 8 \
  --progress
```

### Option B — aws CLI (S3-compatible)

```bash
aws configure set aws_access_key_id     "$B2_KEY_ID"
aws configure set aws_secret_access_key "$B2_APP_KEY"
aws --endpoint-url https://s3.us-west-001.backblazeb2.com \
  s3 cp s3://vm-images-sebdanielsson/windows-server-2025-vs2026.qcow2 ./
```

### Option C — official b2 CLI

```bash
export B2_APPLICATION_KEY_ID="$B2_KEY_ID" B2_APPLICATION_KEY="$B2_APP_KEY"
b2 file download \
  b2://vm-images-sebdanielsson/windows-server-2025-vs2026.qcow2 \
  ./windows-server-2025-vs2026.qcow2
```

After download, sanity-check the size is exactly `41576628224` bytes.

## 2. Prerequisites in the cluster

- OpenShift Virtualization (CNV) operator installed; `kubevirt.io/v1` and
  `cdi.kubevirt.io/v1beta1` CRDs present.
- A storage class that supports the access mode you want. For live migration use
  **RWX** + **`volumeMode: Block`** (block also avoids filesystem overhead, so a
  128 GiB virtual disk fits in a 128 GiB request).
- `virtctl` available locally (from the CNV console "Command line tools", or
  `oc get csv` → krew). Needed for Path A.
- A namespace for the VMs (e.g. `ci-agents`) and, for the golden image, either the
  CNV golden-images namespace `openshift-virtualization-os-images` or a dedicated
  `vm-images` namespace.

## 3. Get the image into the cluster (pick one)

Both paths end at the same place: a **DataSource** that VM definitions clone from.
Keeping the DataSource as the contract means the VM manifests are identical
regardless of how the blob got imported.

### Path A — seed once with virtctl, then GitOps the rest (recommended)

Best honest fit for GitOps: you don't put a 38 GB binary or B2 credentials in the
cluster's declarative state. Seed the golden PVC out-of-band, expose it as a
DataSource, and let ArgoCD manage everything downstream.

```bash
# one-time, from the machine that downloaded the qcow2:
virtctl image-upload dv win2025-vs2026-golden \
  --namespace vm-images \
  --size 130Gi \
  --image-path ./windows-server-2025-vs2026.qcow2 \
  --storage-class <your-sc> \
  --block-volume \
  --insecure
```

Then the DataSource (this part IS in git, §4) points at that PVC. Re-run the
`image-upload` (new DV name + bump the DataSource) when you rebuild the image
monthly.

### Path B — declarative CDI import from B2 (fully GitOps, needs a Secret)

ArgoCD applies a DataVolume whose `source.s3` pulls straight from B2. Zero manual
steps, at the cost of a B2 credential Secret in the cluster (seal it — §4.3).

```yaml
# base/golden-datavolume.yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: win2025-vs2026-golden
  namespace: vm-images
  annotations:
    # let CDI bind immediately and don't let Argo prune the populated PVC
    cdi.kubevirt.io/storage.bind.immediate.requested: "true"
    argocd.argoproj.io/sync-options: Prune=false
spec:
  source:
    s3:
      url: "https://s3.us-west-001.backblazeb2.com/vm-images-sebdanielsson/windows-server-2025-vs2026.qcow2"
      secretRef: b2-import-creds        # Secret with accessKeyId / secretKey
  storage:
    volumeMode: Block
    accessModes: ["ReadWriteMany"]
    resources:
      requests:
        storage: 130Gi
```

> Verify the `source.s3` field names against your CDI version (`oc explain
> datavolume.spec.source.s3`). Some CDI builds want path-style URLs (as above);
> if the import 403s, double-check the key has bucket read and try the
> virtual-host URL `https://vm-images-sebdanielsson.s3.us-west-001.backblazeb2.com/<key>`.

## 4. The kustomize tree

A layout that drops into a typical kustomize + ArgoCD repo:

```text
deploy/windows-ci-agents/
├── base/
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── datasource.yaml          # the clone contract (both paths)
│   ├── golden-datavolume.yaml   # Path B only (S3 import); omit for Path A
│   ├── virtualmachine.yaml      # the Windows VM template
│   └── sysprep-configmap.yaml   # optional per-instance OOBE/enrollment
└── overlays/
    ├── dev/
    │   └── kustomization.yaml
    └── prod/
        └── kustomization.yaml
```

### 4.1 base/datasource.yaml

The VM clones from this; it decouples the VM from how the blob was imported.

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataSource
metadata:
  name: win2025-vs2026
  namespace: vm-images
spec:
  source:
    pvc:
      namespace: vm-images
      name: win2025-vs2026-golden   # PVC from Path A (virtctl) or Path B (DataVolume)
```

### 4.2 base/kustomization.yaml

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ci-agents
resources:
  - namespace.yaml
  - datasource.yaml
  # - golden-datavolume.yaml   # uncomment for Path B
  - virtualmachine.yaml
  # - sysprep-configmap.yaml   # uncomment to inject per-instance config
```

### 4.3 The B2 import Secret (Path B only — never commit raw)

CDI needs a Secret with `accessKeyId` + `secretKey`. Do **not** put the plaintext
Secret in git. Use whatever the repo already uses — SealedSecrets or
ExternalSecrets. Raw shape (for sealing only):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: b2-import-creds
  namespace: vm-images
type: Opaque
stringData:
  accessKeyId: "<B2 keyID>"
  secretKey:   "<B2 application key>"
```

```bash
# SealedSecrets example — the sealed output is safe to commit:
kubeseal --controller-namespace sealed-secrets --format yaml \
  < b2-import-creds.secret.yaml > base/b2-import-creds.sealedsecret.yaml
rm b2-import-creds.secret.yaml   # never commit the raw one
```

## 5. base/virtualmachine.yaml (Windows-tuned)

Clones the golden image per VM via `sourceRef` → DataSource (template stays
pristine), with the Hyper-V enlightenments and clock/timer settings Windows wants.
EFI is enabled; the Packer efivars.fd is irrelevant here.

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: win-ci-agent-01
  labels:
    app: windows-ci-agent
spec:
  runStrategy: Always              # preferred over the older `running: true`
  dataVolumeTemplates:
    - metadata:
        name: win-ci-agent-01-root
      spec:
        storage:
          volumeMode: Block
          accessModes: ["ReadWriteMany"]   # RWX enables live migration
          resources:
            requests:
              storage: 130Gi
        sourceRef:
          kind: DataSource
          namespace: vm-images
          name: win2025-vs2026
  template:
    metadata:
      labels:
        kubevirt.io/domain: win-ci-agent-01
    spec:
      domain:
        cpu:
          cores: 4
          sockets: 1
          threads: 1
        memory:
          guest: 6Gi
        firmware:
          bootloader:
            efi:
              secureBoot: false      # image installs fine without it; set true + smm to match the build
        features:
          acpi: {}
          # smm: { enabled: true }   # required if secureBoot: true
          hyperv:                    # Windows enlightenments — big perf win
            relaxed: {}
            vapic: {}
            vpindex: {}
            synic: {}
            synictimer: { direct: {} }
            spinlocks: { spinlocks: 8191 }
            reenlightenment: {}
            frequencies: {}
            tlbflush: {}
            ipi: {}
            runtime: {}
        clock:
          utc: {}
          timer:
            hpet: { present: false }
            pit: { tickPolicy: delay }
            rtc: { tickPolicy: catchup }
            hyperv: {}
        devices:
          disks:
            - name: rootdisk
              disk: { bus: virtio }   # virtio drivers are baked in (viostor/vioscsi)
            # - name: sysprep         # uncomment with §6
            #   cdrom: { bus: sata }
          interfaces:
            - name: default
              masquerade: {}
              model: virtio           # NetKVM is baked in
        machine:
          type: q35
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          dataVolume:
            name: win-ci-agent-01-root
        # - name: sysprep
        #   sysprep:
        #     configMap: { name: win2025-sysprep }   # or secret: for the PAT
```

Scale the fleet by adding more `VirtualMachine` resources (each clones the golden
DataSource and OOBEs to a unique hostname). With kustomize, template them with a
`namePrefix`/`nameSuffix` per overlay, or generate N copies — keep one VM per file
for clarity.

## 6. Per-instance config & agent enrollment (optional)

A bare boot already yields a working, uniquely-named Windows VM. To turn it into a
specific CI agent at boot, enroll with the runner's **own** scripts — the exact
`config.cmd` invocations (run as the local-admin `.\builder` account) are in
**`OPENSHIFT.md` §4**. Two ways to deliver them:

- **cloudbase-init** (baked into the image): attach a `cloudInitConfigDrive` whose
  `user_data` is a PowerShell script that applies proxy/CA, then runs `config.cmd`
  with values from a Secret. The declarative, GitOps-native path.
- **sysprep `FirstLogonCommand`**: run the same `config.cmd` from the OOBE
  `autounattend.xml` (ConfigMap `base/sysprep-configmap.yaml` for non-secret bits).

For the agent PAT / registration token (and the `builder` password), use a
**Secret** and seal it (SealedSecret/ExternalSecret as in §4.3) — never commit the
raw token.

Certs (internal CA) and proxy (`HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY`) inside the
guest: see **`RUNTIME-CONFIG.md`** — run those **before** enrolling (the
cloudbase-init `user_data` / FirstLogonCommand does this first).

## 7. The ArgoCD Application

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: windows-ci-agents
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://<your-gitops-repo>.git
    targetRevision: main
    path: deploy/windows-ci-agents/overlays/prod
  destination:
    server: https://kubernetes.default.svc
    namespace: ci-agents
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true        # KubeVirt/CDI CRDs are large — avoids last-applied annotation bloat
  ignoreDifferences:
    # KubeVirt mutates VM status/spec at runtime; don't fight it
    - group: kubevirt.io
      kind: VirtualMachine
      jsonPointers:
        - /spec/template/spec/domain/resources
    - group: cdi.kubevirt.io
      kind: DataVolume
      jsonPointers:
        - /spec/source        # CDI clears the source after import completes
```

Gotchas that bite ArgoCD + KubeVirt/CDI:

- **Don't let Argo prune the golden image.** The import DataVolume/PVC is populated
  once; mark it `argocd.argoproj.io/sync-options: Prune=false` (shown in §3 Path B)
  or keep the golden image in a separate Application that you sync manually. A prune
  here means re-downloading 38 GB.
- **CDI rewrites DataVolume `spec.source` to empty after a successful import**, so
  ArgoCD will show it OutOfSync forever unless you `ignoreDifferences` on
  `/spec/source` (above).
- **`runStrategy`/VM status churn**: KubeVirt updates the VM; ServerSideApply +
  the ignoreDifferences above keep it from flapping. If a VM still flaps, add its
  specific runtime-managed fields.
- **Use ServerSideApply** — KubeVirt VM specs exceed the 256 KB last-applied
  annotation limit on older client-side apply.

## 8. Verify a running VM

```bash
oc get vm,vmi,dv,pvc -n ci-agents
virtctl console win-ci-agent-01 -n ci-agents     # or `virtctl vnc ...`
```

Expect: VM `Running`, the DataVolume `Succeeded`, and on first boot a short OOBE
that lands on a clean desktop with a unique hostname (no language prompt). From a
guest shell, confirm the tooling the same way the build was verified: `pwsh
--version`, `dotnet --version`, `vswhere`, `C:\azp\agent\config.cmd` and
`C:\actions-runner\config.cmd` present, and `Get-Service wuauserv` = Disabled.

## 9. Network egress to whitelist

The build captured every domain it reached into `domains-ALL.txt` (74 hosts:
`*.microsoft.com`, `aka.ms`, `github.com`, `dl.google.com`, VS/.NET/Chrome/agent
CDNs, OCSP/CRL). At runtime the agents additionally need your **Azure DevOps /
GitHub endpoints** and whatever the pipelines themselves pull. Give the egress
firewall/proxy `domains-ALL.txt` plus those, and configure the in-guest proxy per
`RUNTIME-CONFIG.md`.
