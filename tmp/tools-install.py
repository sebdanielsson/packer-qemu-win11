#!/usr/bin/env python3
# In-place: wait for OOBE/WinRM on the golden VM (port 4405), install dev-tools
# (Chrome + mise), then verify. Tools script is robust+non-fatal so it self-retries.
import winrm, time
REPO = '/root/packer-qemu-win11'
s = winrm.Session('http://127.0.0.1:4405/wsman', auth=('builder', 'changeme'),
                  transport='basic', operation_timeout_sec=1100, read_timeout_sec=1150)

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

print('installing dev tools (Chrome + mise)...', flush=True)
try:
    r = s.run_ps(open(REPO + '/scripts/install-dev-tools.ps1').read())
    print('devtools rc=%d' % r.status_code, flush=True)
    print(r.std_out.decode()[-1000:], flush=True)
except Exception as e:
    print('client timed out (install continues server-side):', str(e)[:90], flush=True)

# verify (poll; install may still be finishing server-side)
for i in range(40):
    try:
        r = s.run_ps(r'"chrome=" + (Test-Path "C:\Program Files\Google\Chrome\Application\chrome.exe") + " mise=" + (Test-Path "C:\Program Files\mise\bin\mise.exe")')
        v = r.std_out.decode().strip()
        print('verify:', v, flush=True)
        if 'chrome=True' in v and 'mise=True' in v:
            print('TOOLS_OK', flush=True); raise SystemExit(0)
    except SystemExit:
        raise
    except Exception:
        pass
    time.sleep(20)
print('TOOLS_INCOMPLETE', flush=True)
raise SystemExit(2)
