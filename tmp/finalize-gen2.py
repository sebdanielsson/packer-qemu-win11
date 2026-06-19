#!/usr/bin/env python3
# Re-stage the SkipRearm sysprep-unattend.xml on finh-2025 (port 4406), then
# re-run sysprep /generalize - SkipRearm avoids the rearm-limit error.
import winrm, base64, time, subprocess
REPO = '/root/packer-qemu-win11'
s = winrm.Session('http://127.0.0.1:4406/wsman', auth=('builder', 'changeme'),
                  transport='basic', operation_timeout_sec=120, read_timeout_sec=130)

def alive():
    return subprocess.run(['pgrep', '-f', 'qemu-system.*finh-2025'], capture_output=True).returncode == 0

def run(ps):
    for attempt in range(3):
        try:
            return s.run_ps(ps)
        except Exception as e:
            print('  winrm retry (%s)' % str(e)[:60], flush=True); time.sleep(5)
    raise RuntimeError('winrm failed 3x')

# re-stage the updated answer file (chunked base64)
guest = r'C:\sysprep-unattend.xml'
tmp = guest + '.b64'
b64 = base64.b64encode(open(REPO + '/answer_files/windows-2025-x64/sysprep-unattend.xml', 'rb').read()).decode()
run("Remove-Item -Force -EA SilentlyContinue '%s'" % tmp)
for j in range(0, len(b64), 2000):
    run("Add-Content -NoNewline -Path '%s' -Value '%s'" % (tmp, b64[j:j+2000]))
run("[IO.File]::WriteAllBytes('%s',[Convert]::FromBase64String(((Get-Content '%s' -Raw) -replace '\\s','')));Remove-Item -Force '%s'" % (guest, tmp, tmp))
print('re-staged sysprep-unattend.xml (%d bytes)' % run("(Get-Item '%s').Length" % guest).std_out.decode().strip().__len__(), flush=True)
print('unattend len ok', flush=True)

print('invoking sysprep /generalize /oobe /shutdown /quiet /mode:vm (SkipRearm)...', flush=True)
cmd = r'& $env:windir\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /quiet /mode:vm /unattend:C:\sysprep-unattend.xml; "exit=" + $LASTEXITCODE'
try:
    r = s.run_ps(cmd)
    print('sysprep returned EARLY rc=%d %s' % (r.status_code, r.std_out.decode()[-150:]), flush=True)
except Exception as e:
    print('client timed out (sysprep server-side):', str(e)[:90], flush=True)

for i in range(150):
    time.sleep(10)
    if not alive():
        print('SYSPREP_OK: powered off after ~%ds' % (i * 10), flush=True); raise SystemExit(0)
print('STILL_UP after ~25min', flush=True); raise SystemExit(2)
