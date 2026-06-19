#!/usr/bin/env python3
# Host-side: on the running golden VM, trigger sysprep /generalize async, then
# decide success (qemu powers off) vs failure (read setuperr.log). Ops one-off.
import winrm, time, subprocess

s = winrm.Session('http://127.0.0.1:4399/wsman', auth=('builder', 'changeme'),
                  transport='basic', operation_timeout_sec=50, read_timeout_sec=60)

def alive():
    return subprocess.run(['pgrep', '-f', 'qemu-system.*gen-2025'],
                          capture_output=True).returncode == 0

# 1. wait for WinRM to actually respond
ready = False
for i in range(36):
    try:
        r = s.run_ps('hostname')
        if r.status_code == 0 and r.std_out.strip():
            print('winrm ready, host =', r.std_out.decode().strip()); ready = True; break
    except Exception:
        pass
    time.sleep(10)
if not ready:
    print('WINRM_NOT_READY'); raise SystemExit(1)

# 2. launch sysprep generalize async (it powers the VM off on success)
print('launching sysprep /generalize /oobe /shutdown /mode:vm ...')
launch = r'''Start-Process -FilePath "$env:windir\System32\Sysprep\sysprep.exe" -ArgumentList @('/generalize','/oobe','/shutdown','/mode:vm','/unattend:C:\sysprep-unattend.xml')'''
try:
    s.run_ps(launch)
except Exception as e:
    print('launch call note:', str(e)[:120])

# 3. poll: success = VM powers off; failure = stays up past deadline
for i in range(60):                         # up to ~10 min
    time.sleep(10)
    if not alive():
        print('SYSPREP_OK: VM powered off (generalized) after ~%ds' % (i*10)); raise SystemExit(0)
print('VM still up after deadline — sysprep likely FAILED, reading setuperr.log...')
try:
    r = s.run_ps(r'Get-Content C:\Windows\System32\Sysprep\Panther\setuperr.log -Tail 30 -ErrorAction SilentlyContinue')
    print(r.std_out.decode())
except Exception as e:
    print('could not read setuperr.log:', str(e)[:120])
print('SYSPREP_FAILED')
raise SystemExit(2)
