# Install Visual Studio Professional (trial) with selected workloads
# Run as Administrator

$ErrorActionPreference = 'Stop'

Write-Host "=== Step 1/1: Installing Visual Studio Professional ==="

$bootstrapper = "$env:TEMP\vs_professional.exe"

Write-Host "Downloading Visual Studio Professional bootstrapper..."
Invoke-WebRequest -Uri 'https://aka.ms/vs/stable/vs_professional.exe' `
    -OutFile $bootstrapper -UseBasicParsing

Write-Host "Installing Visual Studio Professional..."
# Start-Process -Wait -PassThru is required: VS bootstrapper is a GUI app so & operator
# returns immediately without setting $LASTEXITCODE. Each arg must be listed separately;
# passing -ArgumentList $array joins elements into one string, causing exit code 87.
$process = Start-Process -FilePath $bootstrapper -ArgumentList `
    '--quiet', '--wait', '--norestart', `
    '--add', 'Microsoft.VisualStudio.Workload.ManagedDesktop', `
    '--add', 'Microsoft.VisualStudio.Workload.NetWeb', `
    '--add', 'Microsoft.VisualStudio.Workload.Azure', `
    '--add', 'Microsoft.VisualStudio.Workload.NativeDesktop', `
    '--includeRecommended' `
    -Wait -PassThru
$vsExitCode = $process.ExitCode

if ($vsExitCode -notin @(0, 3010)) {
    Write-Error "VS install failed with exit code $vsExitCode"
    exit $vsExitCode
}
Write-Host "Visual Studio Professional installed (exit code $vsExitCode)"

# Install .NET 10 SDK (not yet in VS installer, install separately)
Write-Host "Installing .NET 10 SDK..."
Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' `
    -OutFile "$env:TEMP\dotnet-install.ps1" -UseBasicParsing
& "$env:TEMP\dotnet-install.ps1" -Channel 10.0 -InstallDir 'C:\Program Files\dotnet'

# Install latest stable PowerShell (7.x)
Write-Host "Installing latest stable PowerShell..."
Invoke-WebRequest -Uri 'https://aka.ms/install-powershell.ps1' `
    -OutFile "$env:TEMP\install-powershell.ps1" -UseBasicParsing
& "$env:TEMP\install-powershell.ps1" -UseMSI -Quiet

Write-Host "Done."
