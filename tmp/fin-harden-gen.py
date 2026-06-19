#!/usr/bin/env python3
# Apply full harden (incl DisablePrivacyExperience), then re-generalize. finh-2025, port 4406.
import winrm, time, subprocess
REPO = '/root/packer-qemu-win11'
s = winrm.Session('http://127.0.0.1:4406/wsman', auth=('builder', 'changeme'),
                  transport='basic', operation_timeout_sec=120, read_timeout_sec=130)

def alive():
    return subprocess.run(['pgrep', '-f', 'qemu-system.*finh-2025'], capture_output=True).returncode == 0

ready = False
for i in range(50):
    try:
        r = s.run_ps('hostname')
        if r.status_code == 0 and r.std_out.strip():
            print('winrm ready:', r.std_out.decode().strip(), flush=True); ready = True; break
    except Exception:
        pass
    time.sleep(10)
if not ready:
    print('WINRM_NOT_READY', flush=True); raise SystemExit(1)

print('applying full harden (DisablePrivacyExperience etc.)...', flush=True)
r = s.run_ps(open(REPO + '/scripts/harden-build-server.ps1').read())
print('harden rc=%d %s' % (r.status_code, r.std_out.decode()[-300:]), flush=True)
# confirm the privacy key
r = s.run_ps(r'"privacy=" + (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE" -Name DisablePrivacyExperience -EA SilentlyContinue).DisablePrivacyExperience')
print(r.std_out.decode().strip(), flush=True)

print('clearing SD + sysprep generalize...', flush=True)
clear = r'''
foreach ($svc in 'wuauserv','UsoSvc','WaaSMedicSvc','bits') { Stop-Service -Force -Name $svc -EA SilentlyContinue; Set-Service -Name $svc -StartupType Disabled -EA SilentlyContinue }
Start-Sleep 2
$sd='C:\Windows\SoftwareDistribution'
if (Test-Path $sd) { try { Rename-Item $sd ("SoftwareDistribution.bak_"+(Get-Date -Format 'yyyyMMddHHmmss')) -EA Stop; 'renamed SD' } catch { 'SD: '+$_ } } else { 'no SD' }
'''
print('clear:', s.run_ps(clear).std_out.decode().strip()[-120:], flush=True)
cmd = r'& $env:windir\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /quiet /mode:vm /unattend:C:\sysprep-unattend.xml; "exit=" + $LASTEXITCODE'
try:
    r = s.run_ps(cmd)
    print('sysprep returned EARLY rc=%d %s' % (r.status_code, r.std_out.decode()[-150:]), flush=True)
except Exception as e:
    print('client timed out (sysprep running server-side):', str(e)[:90], flush=True)

for i in range(150):
    time.sleep(10)
    if not alive():
        print('SYSPREP_OK: powered off after ~%ds' % (i * 10), flush=True); raise SystemExit(0)
print('STILL_UP after ~25min', flush=True); raise SystemExit(2)
