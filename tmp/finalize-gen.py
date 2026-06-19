#!/usr/bin/env python3
# Generalize the final image (WU already disabled + fresh reboot). Port 4399, qemu finalize-2025.
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

# confirm WU is disabled (it should be, from the image)
r = s.run_ps('(Get-Service wuauserv).StartType')
print('wuauserv StartType =', r.std_out.decode().strip(), flush=True)

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
try:
    r = s.run_ps(r'Get-Content C:\Windows\System32\Sysprep\Panther\setupact.log -Tail 6 -ErrorAction SilentlyContinue')
    print(r.std_out.decode(), flush=True)
except Exception:
    pass
raise SystemExit(2)
