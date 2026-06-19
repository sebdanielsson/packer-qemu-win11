#!/usr/bin/env python3
# In-place prep of the agent-bundled base: disable WU + bundle GitHub runner +
# stage helper scripts. Run on the host against the prep VM (port 4399).
import winrm, base64, os, time
REPO = '/root/packer-qemu-win11'
s = winrm.Session('http://127.0.0.1:4399/wsman', auth=('builder', 'changeme'),
                  transport='basic', operation_timeout_sec=120, read_timeout_sec=130)

def run(ps, label=None, ignore_timeout=False):
    try:
        r = s.run_ps(ps)
        if label:
            print('%s: rc=%d %s' % (label, r.status_code, r.std_out.decode()[-300:]), flush=True)
        return r
    except Exception as e:
        if ignore_timeout:
            print('%s: client timeout, continuing (%s)' % (label, str(e)[:70]), flush=True)
            return None
        raise

for i in range(40):
    try:
        if s.run_ps('hostname').std_out.strip():
            print('winrm ready', flush=True); break
    except Exception:
        pass
    time.sleep(10)

run(open(REPO + '/scripts/disable-windows-update.ps1').read(), 'disable-WU')

print('installing github runner (slow extract)...', flush=True)
run(open(REPO + '/scripts/install-github-runner.ps1').read(), 'install-github', ignore_timeout=True)
for i in range(80):
    r = run(r'Test-Path C:\actions-runner\.bundled-runner.json')
    if r and r.std_out.decode().strip() == 'True':
        print('github bundled after ~%ds' % (i * 15), flush=True); break
    time.sleep(15)

def put(local, guest):
    b64 = base64.b64encode(open(local, 'rb').read()).decode()
    tmp = guest + '.b64'
    run("Remove-Item -Force -EA SilentlyContinue '%s'; $d=Split-Path -Parent '%s'; New-Item -ItemType Directory -Force -Path $d|Out-Null" % (tmp, guest))
    for j in range(0, len(b64), 2000):
        run("Add-Content -NoNewline -Path '%s' -Value '%s'" % (tmp, b64[j:j+2000]))
    run("[IO.File]::WriteAllBytes('%s',[Convert]::FromBase64String(((Get-Content '%s' -Raw) -replace '\\s','')));Remove-Item -Force '%s'" % (guest, tmp, tmp),
        'put ' + os.path.basename(guest))

put(REPO + '/scripts/enroll-github-runner.ps1', r'C:\actions-runner\enroll-github-runner.ps1')
put(REPO + '/answer_files/windows-2025-x64/sysprep-unattend.xml', r'C:\sysprep-unattend.xml')
put(REPO + '/scripts/sysprep-generalize.ps1', r'C:\sysprep-generalize.ps1')

run(r"'azure='+(Test-Path C:\azp\agent\config.cmd); 'github='+(Test-Path C:\actions-runner\config.cmd); 'wuauserv='+((Get-Service wuauserv).StartType); 'gh_enroll='+(Test-Path C:\actions-runner\enroll-github-runner.ps1)", 'verify')
print('PREP_DONE', flush=True)
