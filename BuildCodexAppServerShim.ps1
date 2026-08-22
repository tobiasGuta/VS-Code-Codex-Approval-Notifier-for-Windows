[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TargetCodexPath,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'shim-build')
)

$ErrorActionPreference = 'Stop'

function Find-CSharpCompiler {
    $candidates = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    $command = Get-Command csc.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) {
        return $command.Source
    }

    throw 'Could not find a Windows C# compiler (csc.exe). Expected the .NET Framework compiler under %WINDIR%\Microsoft.NET\Framework64 or Framework.'
}

$target = (Resolve-Path -LiteralPath $TargetCodexPath).Path
if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
    throw "Codex target not found: $TargetCodexPath"
}

$sourcePath = Join-Path $PSScriptRoot 'CodexAppServerShim.cs'
if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw "Shim source not found: $sourcePath"
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$outputDirectoryResolved = (Resolve-Path -LiteralPath $OutputDirectory).Path
$outputExe = Join-Path $outputDirectoryResolved 'CodexAppServerShim.exe'
$targetFile = Join-Path $outputDirectoryResolved 'CodexAppServerShim.target'

Remove-Item -LiteralPath $outputExe -Force -ErrorAction SilentlyContinue

$csc = Find-CSharpCompiler
$compilerArgs = @(
    '/nologo',
    '/target:exe',
    '/optimize+',
    "/out:$outputExe",
    $sourcePath
)

$compilerOutput = @(& $csc @compilerArgs 2>&1 | ForEach-Object { [string]$_ })
$compilerExitCode = $LASTEXITCODE
if ($compilerExitCode -ne 0) {
    if ($compilerOutput.Count -gt 0) {
        $compilerOutput | ForEach-Object { Write-Host $_ }
    }
    throw "C# compiler failed with exit code $compilerExitCode."
}

if (-not (Test-Path -LiteralPath $outputExe -PathType Leaf)) {
    throw "Shim executable was not created: $outputExe"
}

Set-Content -LiteralPath $targetFile -Value $target -Encoding UTF8

Write-Host 'Codex app-server shim built.'
Write-Host "Compiler: $csc"
Write-Host "Shim:     $outputExe"
Write-Host "Target:   $target"
Write-Host ''
Write-Host 'The shim is not enabled in VS Code by this script.'
Write-Host 'Use Test-CodexAppServerShim.ps1 before configuring chatgpt.cliExecutable.'
