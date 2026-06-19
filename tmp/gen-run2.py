#!/usr/bin/env python3
# Generalize via SYNCHRONOUS sysprep over WinRM. The client read-times-out while
# sysprep runs, but the server-side process continues (and powers off on success).
import winrm, time, subprocess

s = winrm.Session('http://127.0.0.1:4399/wsman', auth=('builder', 'changeme'),
                  transport='basic', operation_timeout_sec=80, read_timeout_sec=90)

def alive():
    return subprocess.run(['pgrep', '-f', 'qemu-system.*gen-2025'],
                          capture_output=True).returncode == 0

print('invoking sysprep synchronously (/generalize /oobe /shutdown /mode:vm)...', flush=True)
cmd = r'& $env:windir\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /mode:vm /unattend:C:\sysprep-unattend.xml; "sysprep_exit=" + $LASTEXITCODE'
try:
    r = s.run_ps(cmd)
    print('sysprep returned EARLY rc=%d out=%s' % (r.status_code, r.std_out.decode()[-400:]), flush=True)
    if r.std_err:
        print('err:', r.std_err.decode()[-400:], flush=True)
except Exception as e:
    print('client timed out/disconnected (sysprep running server-side):', str(e)[:120], flush=True)

# poll for power-off (generalize on slow raidz1 can take a while)
for i in range(150):                 # up to ~25 min
    time.sleep(10)
    if not alive():
        print('SYSPREP_OK: powered off (generalized) after ~%ds' % (i * 10), flush=True)
        raise SystemExit(0)
print('STILL_UP after ~25min', flush=True)
raise SystemExit(2)
