#!/usr/bin/env python3
# FINAL generalize attempt: clear WU datastore (SoftwareDistribution) then sysprep.
import winrm, time, subprocess
s = winrm.Session('http://127.0.0.1:4399/wsman', auth=('builder', 'changeme'),
                  transport='basic', operation_timeout_sec=120, read_timeout_sec=130)

def alive():
    return subprocess.run(['pgrep', '-f', 'qemu-system.*finalize-2025'],
                          capture_output=True).returncode == 0

ready = False
for i in range(45):
    try:
        r = s.run_ps('hostname')
        if r.status_code == 0 and r.std_out.strip():
            print('winrm ready:', r.std_out.decode().strip(), flush=True); ready = True; break
    except Exception:
        pass
    time.sleep(10)
if not ready:
    print('WINRM_NOT_READY', flush=True); raise SystemExit(1)

print('clearing WU datastore (SoftwareDistribution)...', flush=True)
clear = r'''
foreach ($svc in 'wuauserv','UsoSvc','WaaSMedicSvc','bits') { Stop-Service -Force -Name $svc -EA SilentlyContinue; Set-Service -Name $svc -StartupType Disabled -EA SilentlyContinue }
Start-Sleep 2
$sd='C:\Windows\SoftwareDistribution'
if (Test-Path $sd) { try { Rename-Item $sd ("SoftwareDistribution.bak_"+(Get-Date -Format 'yyyyMMddHHmmss')) -EA Stop; 'renamed SD' } catch { 'SD rename failed: '+$_ } } else { 'no SD' }
'''
r = s.run_ps(clear)
print('clear result:', r.std_out.decode().strip()[-200:], flush=True)

print('invoking sysprep /generalize /oobe /shutdown /quiet /mode:vm ...', flush=True)
cmd = r'& $env:windir\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /quiet /mode:vm /unattend:C:\sysprep-unattend.xml; "exit=" + $LASTEXITCODE'
try:
    r = s.run_ps(cmd)
    print('sysprep returned EARLY rc=%d out=%s' % (r.status_code, r.std_out.decode()[-300:]), flush=True)
except Exception as e:
    print('client timed out (sysprep running server-side):', str(e)[:100], flush=True)

for i in range(150):                 # up to ~25 min
    time.sleep(10)
    if not alive():
        print('SYSPREP_OK: powered off (generalized) after ~%ds' % (i * 10), flush=True)
        raise SystemExit(0)
print('STILL_UP after ~25min', flush=True)
raise SystemExit(2)
