# Runtime configuration (certs & proxy)

How to add self-signed/internal CA certificates and configure an outbound proxy
on the Windows agent image. Each can be done two ways:

- **Bake into the image** — add a provisioner step in `windows.pkr.hcl` so every
  build has it (best for org-wide CAs / a fixed corporate proxy).
- **At deploy time** — run on the deployed VM (e.g. from a KubeVirt sysprep
  `FirstLogonCommand`, a startup script, or `enroll.json`-style drop-in). Best
  when the value differs per environment.

All snippets are PowerShell, run elevated (the image's `builder` is admin).

## 1. Self-signed / internal CA certificates -> system trust store

Put your CA/cert `.cer`/`.crt` files somewhere on the VM, then import into the
**LocalMachine** stores (machine-wide; survives sysprep generalize):

```powershell
# Root CA  -> Trusted Root Certification Authorities
Import-Certificate -FilePath C:\certs\my-root-ca.cer -CertStoreLocation Cert:\LocalMachine\Root

# Intermediate CA -> Intermediate Certification Authorities
Import-Certificate -FilePath C:\certs\my-intermediate-ca.cer -CertStoreLocation Cert:\LocalMachine\CA

# Or, equivalently, with certutil:
certutil -addstore -f Root C:\certs\my-root-ca.cer
```

Bulk-import a folder of CAs:

```powershell
Get-ChildItem C:\certs\*.cer | ForEach-Object {
    Import-Certificate -FilePath $_.FullName -CertStoreLocation Cert:\LocalMachine\Root
}
```

To **bake into the image**, drop the `.cer` files in `certs/` and add to the build:

```hcl
provisioner "file" {
  source      = "certs/"
  destination = "C:\\certs"
}
provisioner "powershell" {
  inline = ["Get-ChildItem C:\\certs\\*.cer | ForEach-Object { Import-Certificate -FilePath $_.FullName -CertStoreLocation Cert:\\LocalMachine\\Root }"]
}
```

Notes:
- The Windows system store covers most tooling (schannel, .NET, MSI, the agents).
- Tools with their **own** CA bundle need separate handling: **git** ->
  `git config --system http.sslCAInfo` or set `GIT_SSL_CAINFO`; **Node** ->
  `NODE_EXTRA_CA_CERTS`; **curl** -> `CURL_CA_BUNDLE`. Point these at a PEM of your
  CA (set as machine env vars, see below).

## 2. Outbound proxy

Two layers usually both need setting on a build agent:

### a) Windows system proxy (WinHTTP) - used by services, the Azure agent service, MSI, etc.
```powershell
netsh winhttp set proxy proxy-server="http=proxy.example.local:8080;https=proxy.example.local:8080" `
    bypass-list="localhost;127.0.0.1;*.example.local;<local>"
# verify / reset:
netsh winhttp show proxy
# netsh winhttp reset proxy
```

### b) WinINET per-user proxy - used by interactive apps (Edge/Chrome/IE)
```powershell
$reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
Set-ItemProperty $reg ProxyServer 'proxy.example.local:8080'
Set-ItemProperty $reg ProxyEnable 1
Set-ItemProperty $reg ProxyOverride 'localhost;127.0.0.1;*.example.local;<local>'
```
(For an autologon service-agent these per-user settings often don't matter; the
env vars below cover most CLI tooling.)

### c) Environment variables - mise, git, curl, dotnet, node, gh, many CLIs
Set machine-wide so all sessions/services inherit them:
```powershell
[Environment]::SetEnvironmentVariable('HTTP_PROXY',  'http://proxy.example.local:8080', 'Machine')
[Environment]::SetEnvironmentVariable('HTTPS_PROXY', 'http://proxy.example.local:8080', 'Machine')
[Environment]::SetEnvironmentVariable('NO_PROXY',    'localhost,127.0.0.1,.example.local', 'Machine')
# Some tools read the lowercase forms too:
[Environment]::SetEnvironmentVariable('http_proxy',  'http://proxy.example.local:8080', 'Machine')
[Environment]::SetEnvironmentVariable('https_proxy', 'http://proxy.example.local:8080', 'Machine')
[Environment]::SetEnvironmentVariable('no_proxy',    'localhost,127.0.0.1,.example.local', 'Machine')
```

### CI agents specifically
- **Azure Pipelines agent**: honours `--proxyurl`/`--proxyusername`/`--proxypassword`
  at `config.cmd` time, or a `.proxy` file in the agent dir, or the env vars above.
- **GitHub runner**: honours `HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY` (env or a `.env`
  file in the runner dir).

### Bake a fixed proxy into the image
Add a provisioner running the `netsh winhttp set proxy` + the
`SetEnvironmentVariable(...,'Machine')` calls above. For a per-environment proxy,
do it at deploy time instead.
