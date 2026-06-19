#!/usr/bin/env python3
# Host-side: bundle the Azure Pipelines agent + helper scripts into a running
# golden-image VM over WinRM (Basic), then verify. Not committed (ops one-off).
import winrm, base64, os, sys

REPO = '/root/packer-qemu-win11'
PORT = 4399
s = winrm.Session(f'http://127.0.0.1:{PORT}/wsman', auth=('builder', 'changeme'),
                  transport='basic', operation_timeout_sec=800, read_timeout_sec=900)

def ps(script, label):
    r = s.run_ps(script)
    out = r.std_out.decode(errors='replace').strip()
    print(f"--- {label}: rc={r.status_code}")
    if out: print(out[-2500:])
    if r.status_code != 0:
        print("STDERR:", r.std_err.decode(errors='replace')[-1500:])
        raise SystemExit(f"{label} FAILED")

# 1. Bundle the agent (downloads in-guest via NAT).
print(">>> installing agent (downloads ~252MB in guest, be patient)...")
ps(open(f'{REPO}/scripts/install-azure-pipelines-agent.ps1').read(), "install-agent")

# 2. Stage helper files into the guest via base64.
def put(local, guest):
    b64 = base64.b64encode(open(local, 'rb').read()).decode()
    ps(f"""$d=Split-Path -Parent '{guest}'; New-Item -ItemType Directory -Force -Path $d|Out-Null;
[IO.File]::WriteAllBytes('{guest}',[Convert]::FromBase64String('{b64}'));
"wrote {guest} ($((Get-Item '{guest}').Length) bytes)" """, f"put {os.path.basename(guest)}")

put(f'{REPO}/scripts/enroll-azure-pipelines-agent.ps1', 'C:\\azp\\enroll-azure-pipelines-agent.ps1')
put(f'{REPO}/answer_files/windows-2025-x64/sysprep-unattend.xml', 'C:\\sysprep-unattend.xml')
put(f'{REPO}/scripts/sysprep-generalize.ps1', 'C:\\sysprep-generalize.ps1')

# 3. Verify.
ps("""'config.cmd present: ' + (Test-Path C:\\azp\\agent\\config.cmd)
'bundled: ' + (Get-Content C:\\azp\\agent\\.bundled-agent.json -Raw)
'C:\\azp contents:'; Get-ChildItem C:\\azp | Select-Object Name | Format-Table -HideTableHeaders
'sysprep files: ' + (Test-Path C:\\sysprep-unattend.xml) + ' ' + (Test-Path C:\\sysprep-generalize.ps1)""", "verify")
print("BUNDLE OK")
