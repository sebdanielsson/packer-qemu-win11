# Install the latest stable PowerShell 7 (MSI). Lives in the BASE image since
# it is broadly useful. ASCII only (Windows PowerShell reads .ps1 as ANSI).
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "=== Installing latest stable PowerShell 7 ==="
$installer = "$env:TEMP\install-powershell.ps1"
Invoke-WebRequest -Uri 'https://aka.ms/install-powershell.ps1' -OutFile $installer -UseBasicParsing
& $installer -UseMSI -Quiet
Write-Host "PowerShell 7 installed."
