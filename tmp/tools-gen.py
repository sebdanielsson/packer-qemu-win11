#!/usr/bin/env python3
# Re-generalize the in-place golden VM (tools-2025, port 4405) after adding tools.
import winrm, time, subprocess
s = winrm.Session('http://127.0.0.1:4405/wsman', auth=('builder', 'changeme'),
                  transport='basic', operation_timeout_sec=120, read_timeout_sec=130)

def alive():
    return subprocess.run(['pgrep', '-f', 'qemu-system.*tools-2025'],
                          capture_output=True).returncode == 0

print('clearing WU datastore + stopping WU services...', flush=True)
clear = r'''
foreach ($svc in 'wuauserv','UsoSvc','WaaSMedicSvc','bits') { Stop-Service -Force -Name $svc -EA SilentlyContinue; Set-Service -Name $svc -StartupType Disabled -EA SilentlyContinue }
Start-Sleep 2
$sd='C:\Windows\SoftwareDistribution'
if (Test-Path $sd) { try { Rename-Item $sd ("SoftwareDistribution.bak_"+(Get-Date -Format 'yyyyMMddHHmmss')) -EA Stop; 'renamed SD' } catch { 'SD: '+$_ } } else { 'no SD' }
'''
print('clear:', s.run_ps(clear).std_out.decode().strip()[-120:], flush=True)

print('invoking sysprep /generalize /oobe /shutdown /quiet /mode:vm ...', flush=True)
cmd = r'& $env:windir\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /quiet /mode:vm /unattend:C:\sysprep-unattend.xml; "exit=" + $LASTEXITCODE'
try:
    r = s.run_ps(cmd)
    print('sysprep returned EARLY rc=%d %s' % (r.status_code, r.std_out.decode()[-200:]), flush=True)
except Exception as e:
    print('client timed out (sysprep running server-side):', str(e)[:90], flush=True)

for i in range(150):                 # up to ~25 min
    time.sleep(10)
    if not alive():
        print('SYSPREP_OK: powered off (generalized) after ~%ds' % (i * 10), flush=True)
        raise SystemExit(0)
print('STILL_UP after ~25min', flush=True)
raise SystemExit(2)
