[CmdletBinding()]
param(
    [string]$InnoCompilerPath
)

$ErrorActionPreference = 'Stop'

function Find-Csc {
    foreach ($p in @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )) {
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    throw 'Windows .NET Framework C# compiler was not found.'
}

function Find-Iscc {
    param([string]$Explicit)
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) {
        if (-not (Test-Path -LiteralPath $Explicit -PathType Leaf)) {
            throw "Inno Setup compiler was not found: $Explicit"
        }
        return (Resolve-Path -LiteralPath $Explicit).Path
    }

    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }

    $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) { return $command.Source }

    throw 'Inno Setup 6 was not found. Install Inno Setup 6 or pass -InnoCompilerPath.'
}

function Invoke-BuildScript {
    param(
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][string]$OutputDirectory
    )

    $scriptPath = Join-Path $root $Script
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "Missing build script: $Script" }

    & $windowsPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath -OutputDirectory $OutputDirectory
    if ($LASTEXITCODE -ne 0) { throw "$Script failed with exit code $LASTEXITCODE." }
}

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) { throw 'Windows PowerShell 5.1 is required.' }
$csc = Find-Csc
$iscc = Find-Iscc -Explicit $InnoCompilerPath

$payload = Join-Path $root 'setup-payload'
$output = Join-Path $root 'setup-output'
$installerScript = Join-Path $root 'installer\CodexRemoteApprovals.iss'

foreach ($path in @($payload, $output)) {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

$shimDir = Join-Path $payload 'shim-build'
New-Item -ItemType Directory -Path $shimDir -Force | Out-Null
$shimSource = Join-Path $root 'CodexAppServerShim.cs'
$shimExe = Join-Path $shimDir 'CodexAppServerShim.exe'

& $csc /nologo /target:exe /optimize+ "/out:$shimExe" $shimSource
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $shimExe -PathType Leaf)) {
    throw 'Codex app-server shim compilation failed.'
}
Set-Content -LiteralPath (Join-Path $shimDir 'CodexAppServerShim.mode') -Value 'local-bridge' -Encoding ASCII

Invoke-BuildScript -Script 'BuildCodexLocalCompanion.ps1' -OutputDirectory (Join-Path $payload 'companion-build')
Invoke-BuildScript -Script 'BuildCodexLanGateway.ps1' -OutputDirectory (Join-Path $payload 'gateway-build')
Invoke-BuildScript -Script 'BuildCodexMobileUiServer.ps1' -OutputDirectory (Join-Path $payload 'mobile-build')
Invoke-BuildScript -Script 'BuildCodexRemoteTray.ps1' -OutputDirectory (Join-Path $payload 'tray-build')

foreach ($file in @(
    'Select-CodexLiveThread.ps1',
    'Configure-InstalledRemoteApprovals.ps1',
    'Unconfigure-InstalledRemoteApprovals.ps1'
)) {
    Copy-Item -LiteralPath (Join-Path $root $file) -Destination (Join-Path $payload $file) -Force
}

Copy-Item -LiteralPath (Join-Path $root 'mobile') -Destination (Join-Path $payload 'mobile') -Recurse -Force

$requiredRuntime = @(
    'shim-build\CodexAppServerShim.exe',
    'shim-build\CodexAppServerShim.mode',
    'companion-build\CodexLocalCompanion.exe',
    'gateway-build\CodexLanGateway.exe',
    'mobile-build\CodexMobileUiServer.exe',
    'tray-build\CodexRemoteTray.exe',
    'Select-CodexLiveThread.ps1',
    'Configure-InstalledRemoteApprovals.ps1',
    'Unconfigure-InstalledRemoteApprovals.ps1',
    'mobile\index.html',
    'mobile\app.js',
    'mobile\app.css'
)
foreach ($rel in $requiredRuntime) {
    if (-not (Test-Path -LiteralPath (Join-Path $payload $rel) -PathType Leaf)) {
        throw "Setup payload is incomplete: $rel"
    }
}

if (-not (Test-Path -LiteralPath $installerScript -PathType Leaf)) {
    throw "Inno Setup source was not found: $installerScript"
}

Push-Location (Split-Path -Parent $installerScript)
try {
    & $iscc $installerScript
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup compiler failed with exit code $LASTEXITCODE." }
}
finally {
    Pop-Location
}

$setupExe = Join-Path $output 'CodexRemoteApprovals-Setup.exe'
if (-not (Test-Path -LiteralPath $setupExe -PathType Leaf)) {
    throw "Setup executable was not created: $setupExe"
}

$hash = (Get-FileHash -LiteralPath $setupExe -Algorithm SHA256).Hash
Write-Host ''
Write-Host 'Codex Remote Approvals Setup built.' -ForegroundColor Green
Write-Host "Setup:  $setupExe"
Write-Host "SHA256: $hash"
