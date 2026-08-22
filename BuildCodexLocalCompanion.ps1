[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'companion-build')
)

$ErrorActionPreference = 'Stop'

function Find-CSharpCompiler {
    $candidates = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $command = Get-Command csc.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) { return $command.Source }
    throw 'Could not find csc.exe.'
}

$source = Join-Path $PSScriptRoot 'CodexLocalCompanion.cs'
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Source not found: $source" }

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$outDir = (Resolve-Path -LiteralPath $OutputDirectory).Path
$outputExe = Join-Path $outDir 'CodexLocalCompanion.exe'
Remove-Item -LiteralPath $outputExe -Force -ErrorAction SilentlyContinue

$csc = Find-CSharpCompiler
$frameworkDir = Split-Path -Parent $csc
$webExtensions = Join-Path $frameworkDir 'System.Web.Extensions.dll'
if (-not (Test-Path -LiteralPath $webExtensions -PathType Leaf)) {
    throw "System.Web.Extensions.dll not found next to compiler: $webExtensions"
}

$args = @(
    '/nologo',
    '/target:exe',
    '/optimize+',
    "/out:$outputExe",
    "/reference:$webExtensions",
    $source
)

$output = @(& $csc @args 2>&1 | ForEach-Object { [string]$_ })
if ($LASTEXITCODE -ne 0) {
    $output | ForEach-Object { Write-Host $_ }
    throw "C# compiler failed with exit code $LASTEXITCODE."
}
if (-not (Test-Path -LiteralPath $outputExe -PathType Leaf)) { throw "Companion executable was not created: $outputExe" }

Write-Host 'Codex Local Companion built.'
Write-Host "Compiler: $csc"
Write-Host "Output:   $outputExe"
