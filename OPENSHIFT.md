# Deploying the Server 2025 image on OpenShift Virtualization (KubeVirt)

This covers taking the Packer golden image (`windows-server-2025-vs2026.qcow2`)
to OpenShift Virtualization (OpenShift Container Platform Virtualization / CNV)
and running it as a fleet of Azure Pipelines agents.

## 0. Which image: generalized vs not

- **Non-generalized** (default build): every clone has the same hostname/SID.
  Fine for a single VM or quick test, *not* for a fleet (agent-name and identity
  collisions).
- **Generalized template** (Phase 2 — `generalize=true` build, or run
  `scripts/sysprep-generalize.ps1` on the golden image): each instance runs
  specialize/OOBE on first boot from `sysprep-unattend.xml`, getting a unique
  random hostname + fresh SID. **Use this for the fleet.**

## 1. Upload the qcow2 as a PVC/DataVolume

CDI imports qcow2 directly (no conversion needed). Easiest is `virtctl`:

```bash
virtctl image-upload dv win2025-vs2026-golden \
  --size=128Gi \
  --image-path=./windows-server-2025-vs2026.qcow2 \
  --storage-class=<your-sc> \
  --insecure
```

This creates a DataVolume + PVC `win2025-vs2026-golden` you can clone per VM.
(Alternatively, host the qcow2 over HTTP and use a DataVolume with
`source.http.url`, or push it to a container registry as a
`containerDisk` image.)

## 2. Sysprep answer file as a ConfigMap (or Secret)

KubeVirt's **sysprep** volume presents an `autounattend.xml` to Windows OOBE.
Put the contents of `answer_files/windows-2025-x64/sysprep-unattend.xml` under
the key `autounattend.xml`:

```bash
kubectl create configmap win2025-sysprep \
  --from-file=autounattend.xml=answer_files/windows-2025-x64/sysprep-unattend.xml
```

Use a **Secret** instead of a ConfigMap if you embed the PAT for auto-enrollment
(see §4). KubeVirt supports either as the sysprep source.

## 3. VirtualMachine manifest

Clones the golden PVC per VM (so the template stays pristine) and attaches the
sysprep volume. No vTPM is required; add one only if you later need BitLocker.

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: azp-agent-01
spec:
  running: true
  template:
    metadata:
      labels: { kubevirt.io/domain: azp-agent-01 }
    spec:
      domain:
        cpu: { cores: 4 }
        memory: { guest: 6Gi }
        devices:
          disks:
            - name: rootdisk
              disk: { bus: virtio }      # virtio-scsi/virtio — matches how it was installed
            - name: sysprep
              cdrom: { bus: sata }
          interfaces:
            - name: default
              masquerade: {}
        features:
          smm: { enabled: true }
        firmware:
          bootloader:
            efi: { secureBoot: true }    # image was installed under Secure Boot
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          dataVolume: { name: azp-agent-01-root }
        - name: sysprep
          sysprep:
            configMap: { name: win2025-sysprep }   # or `secret:` if it holds the PAT
  dataVolumeTemplates:
    - metadata: { name: azp-agent-01-root }
      spec:
        storage:
          resources: { requests: { storage: 128Gi } }
        source:
          pvc: { namespace: <ns>, name: win2025-vs2026-golden }   # clone the golden PVC
```

## 4. Auto-enrolling the agent (the part we deferred)

The image ships the agent pre-bundled at `C:\azp\agent` plus
`C:\azp\enroll-azure-pipelines-agent.ps1`. The baked sysprep run executes the
enrollment **only if `C:\azp\enroll.json` exists**. To turn auto-enroll on, make
the sysprep media a **Secret** whose `autounattend.xml` adds a FirstLogonCommand
that writes `enroll.json` before the enrollment command runs, e.g.:

```xml
<SynchronousCommand wcm:action="add">
  <Order>1</Order>
  <CommandLine>cmd /c mkdir C:\azp 2&gt; nul &amp; powershell -Command "@{OrgUrl='https://devops.example.local/DefaultCollection';Pool='windows-vs2026';Token='REPLACE_PAT';Replace=$true} | ConvertTo-Json | Set-Content C:\azp\enroll.json"</CommandLine>
</SynchronousCommand>
```

Then the existing `Order 2` enrollment command picks it up. Keep the PAT in a
Secret, not a ConfigMap. (Alternatively call `config.cmd` directly with the PAT.)

PAT scope required: **Agent Pools (read & manage)**. For on-prem Azure DevOps
Server, `OrgUrl` is the collection URL `https://<server>/<collection>`.

## 5. Notes
- The agent runs as the `VstsAgent` Windows service (auto-start), so the VM
  connects to the pool on boot without an interactive logon.
- Scale by creating more `VirtualMachine` objects (each clones the golden PVC and
  gets a unique hostname via sysprep). Consider an OpenShift VM **template** or a
  small controller to template these out.
