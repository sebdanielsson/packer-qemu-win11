#!/usr/bin/env python3
# Verify the generalized template: wait for auto-OOBE, then report identity + agents.
import winrm, time
s = winrm.Session('http://127.0.0.1:4403/wsman', auth=('builder', 'changeme'),
                  transport='basic', operation_timeout_sec=60, read_timeout_sec=70)

host = None
for i in range(80):                 # up to ~20 min for specialize+OOBE on slow disk
    try:
        r = s.run_ps('hostname')
        if r.status_code == 0 and r.std_out.strip():
            host = r.std_out.decode().strip()
            print('OOBE complete after ~%ds, hostname = %s' % (i * 15, host), flush=True)
            break
    except Exception:
        pass
    time.sleep(15)
if not host:
    print('OOBE_NOT_DONE (winrm never came up)', flush=True); raise SystemExit(1)

r = s.run_ps(r'''
"hostname=" + (hostname)
"user=" + (whoami)
"azure_agent=" + (Test-Path C:\azp\agent\config.cmd)
"github_runner=" + (Test-Path C:\actions-runner\config.cmd)
"wuauserv=" + ((Get-Service wuauserv).StartType)
"vs=" + (& "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe" -property catalog_productDisplayVersion 2>$null)
''')
print(r.std_out.decode(), flush=True)
print('VERIFY_DONE', flush=True)
