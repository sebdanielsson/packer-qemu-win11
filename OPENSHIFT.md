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

The sysprep volume only supplies OOBE identity (unique hostname/SID); agent
enrollment is separate (§4 — via `config.cmd`, or cloudbase-init `user_data`).
KubeVirt accepts either a ConfigMap or a Secret as the sysprep source.

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

## 4. Choosing Azure Pipelines *or* GitHub at deploy time

The image bundles **both** CI agents, **unconfigured**, so one template serves
either. Configure with each runner's **own** scripts at deploy time — no wrapper:

| | bundled at | configure / run / service |
| --- | --- | --- |
| Azure Pipelines | `C:\azp\agent` | `config.cmd` / `run.cmd` / `svc.cmd` |
| GitHub Actions  | `C:\actions-runner` | `config.cmd` / `run.cmd` / `svc.cmd` |

Nothing autostarts until you configure one — that's the boot-time switch.

### Run as the built-in `builder` account

Both `config.cmd`s take the service account natively. Register the service under
the image's local-admin **`.\builder`** (not the default `NT AUTHORITY\NETWORK
SERVICE`): `builder` owns the warm tool profile (mise shims, .NET/NuGet/npm
caches) and a **service logon gets the full admin token**, so jobs can write
`C:\Program Files`, install MSIs, etc. (NETWORK SERVICE can't — that breaks e.g.
`actions/setup-dotnet`).

**Azure Pipelines** (`--url` = where the *pool* lives; for a server-level pool on
Azure DevOps Server that's the bare server root, not a collection/project URL):
```powershell
cd C:\azp\agent
.\config.cmd --unattended `
  --url https://devops.example.local --auth pat --token <PAT> `
  --pool <windows-pool> --work _work `
  --runAsService --windowsLogonAccount ".\builder" --windowsLogonPassword "<builder-pw>"
```

**GitHub Actions** (`--url` = repo / org / enterprise; short-lived registration token):
```powershell
cd C:\actions-runner
.\config.cmd --unattended `
  --url https://github.example.com/enterprises/<slug> --token <registration-token> `
  --runnergroup Default --labels self-hosted,windows,vs2026 --work _work --replace `
  --runasservice --windowslogonaccount ".\builder" --windowslogonpassword "<builder-pw>"
```

For a throwaway test, drop the service flags and run `.\run.cmd` from an elevated
shell. Manage the service with `.\svc.cmd status|start|stop|uninstall`.

Secrets/scopes: Azure PAT needs **Agent Pools (read & manage)**. GitHub needs a
**registration token** (~1h; via the API with a PAT, or Settings → Actions →
Runners) matching the `--url` scope.

### Automated (cloud-init)

Because the image ships **cloudbase-init**, KubeVirt can drive all of the above
declaratively: attach a `cloudInitConfigDrive` whose `user_data` is a PowerShell
script that applies proxy/CA, then runs the `config.cmd` above with values from a
Secret. No sysprep `FirstLogonCommand`, no `enroll.json`.

## 5. Notes
- The configured agent runs as a Windows service under `.\builder` (auto-start),
  so the VM joins the pool on boot without an interactive logon.
- **qemu-guest-agent** is installed, so KubeVirt reports the guest IP/OS
  (`AgentConnected=True`) and can quiesce the filesystem for online snapshots.
- `mise` shims are on `PATH`, so `mise use -g <tool>` is directly invocable; the
  machine execution policy is `Unrestricted` and Developer Mode is on.
- Scale by creating more `VirtualMachine` objects (each clones the golden PVC and
  gets a unique hostname via sysprep). Consider an OpenShift VM **template** or a
  small controller to template these out.
