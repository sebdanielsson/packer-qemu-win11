#!/usr/bin/env python3
# Verify generalize on gtest2 (port 4401): disable WU first, then sysprep.
import winrm, time, subprocess
REPO = '/root/packer-qemu-win11'
s = winrm.Session('http://127.0.0.1:4401/wsman', auth=('builder', 'changeme'),
                  transport='basic', operation_timeout_sec=120, read_timeout_sec=130)

def alive():
    return subprocess.run(['pgrep', '-f', 'qemu-system.*gtest2-2025'],
                          capture_output=True).returncode == 0

ready = False
for i in range(40):
    try:
        r = s.run_ps('hostname')
        if r.status_code == 0 and r.std_out.strip():
            print('winrm ready:', r.std_out.decode().strip(), flush=True); ready = True; break
    except Exception:
        pass
    time.sleep(10)
if not ready:
    print('WINRM_NOT_READY', flush=True); raise SystemExit(1)

print('disabling Windows Update...', flush=True)
try:
    r = s.run_ps(open(REPO + '/scripts/disable-windows-update.ps1').read())
    print('disable-WU rc=%d %s' % (r.status_code, r.std_out.decode()[-400:]), flush=True)
except Exception as e:
    print('disable-WU note:', str(e)[:120], flush=True)

print('invoking sysprep /generalize /oobe /shutdown /quiet /mode:vm ...', flush=True)
cmd = r'& $env:windir\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /quiet /mode:vm /unattend:C:\sysprep-unattend.xml; "exit=" + $LASTEXITCODE'
try:
    r = s.run_ps(cmd)
    print('sysprep returned EARLY rc=%d out=%s' % (r.status_code, r.std_out.decode()[-300:]), flush=True)
except Exception as e:
    print('client timed out (sysprep running server-side):', str(e)[:100], flush=True)

for i in range(120):                 # up to ~20 min
    time.sleep(10)
    if not alive():
        print('SYSPREP_OK: powered off (generalized) after ~%ds' % (i * 10), flush=True)
        raise SystemExit(0)
print('STILL_UP after ~20min', flush=True)
try:
    r = s.run_ps(r'Get-Content C:\Windows\System32\Sysprep\Panther\setupact.log -Tail 6 -ErrorAction SilentlyContinue')
    print(r.std_out.decode(), flush=True)
except Exception:
    pass
raise SystemExit(2)
