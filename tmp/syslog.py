import winrm
s = winrm.Session('http://127.0.0.1:4399/wsman', auth=('builder', 'changeme'),
                  transport='basic', operation_timeout_sec=50, read_timeout_sec=60)
ps = r'''
"--- Panther dir ---"
Get-ChildItem C:\Windows\System32\Sysprep\Panther -ErrorAction SilentlyContinue |
  Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize | Out-String
"--- tag files ---"
Get-ChildItem C:\Windows\System32\Sysprep\*.tag -ErrorAction SilentlyContinue | Select-Object -Expand Name
"--- setupact.log RAW last 30 ---"
Get-Content C:\Windows\System32\Sysprep\Panther\setupact.log -Tail 30 -ErrorAction SilentlyContinue
'''
r = s.run_ps(ps)
print(r.std_out.decode())
