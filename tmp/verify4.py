#!/usr/bin/env python3
# Verify the final generalized template (v4-2025, port 4404): wait for auto-OOBE,
# then report identity, agents, WU state, and the harden settings.
import winrm, time
s = winrm.Session('http://127.0.0.1:4404/wsman', auth=('builder', 'changeme'),
                  transport='basic', operation_timeout_sec=60, read_timeout_sec=70)
host = None
for i in range(90):                 # up to ~22 min
    try:
        r = s.run_ps('hostname')
        if r.status_code == 0 and r.std_out.strip():
            host = r.std_out.decode().strip()
            print('OOBE complete after ~%ds, hostname=%s' % (i * 15, host), flush=True); break
    except Exception:
        pass
    time.sleep(15)
if not host:
    print('OOBE_NOT_DONE', flush=True); raise SystemExit(1)

r = s.run_ps(r'''
"hostname=" + (hostname)
"user=" + (whoami)
"azure_agent=" + (Test-Path C:\azp\agent\config.cmd)
"github_runner=" + (Test-Path C:\actions-runner\config.cmd)
"azure_enroll=" + (Test-Path C:\azp\enroll-azure-pipelines-agent.ps1)
"github_enroll=" + (Test-Path C:\actions-runner\enroll-github-runner.ps1)
"wuauserv=" + ((Get-Service wuauserv).StartType)
"vs=" + (& "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe" -property catalog_productDisplayVersion 2>$null)
"shutdownTracker=" + ((Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Reliability' -Name ShutdownReasonOn -EA SilentlyContinue).ShutdownReasonOn)
"serverMgrNoAutostart=" + ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\ServerManager' -Name DoNotOpenServerManagerAtLogon -EA SilentlyContinue).DoNotOpenServerManagerAtLogon)
''')
print(r.std_out.decode(), flush=True)
print('VERIFY_DONE', flush=True)
