[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TargetCodexPath,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'shim-build')
)

$ErrorActionPreference = 'Stop'

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

$source = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8
Add-Type `
    -TypeDefinition $source `
    -Language CSharp `
    -OutputAssembly $outputExe `
    -OutputType ConsoleApplication

if (-not (Test-Path -LiteralPath $outputExe -PathType Leaf)) {
    throw "Shim executable was not created: $outputExe"
}

Set-Content -LiteralPath $targetFile -Value $target -Encoding UTF8

Write-Host 'Codex app-server shim built.'
Write-Host "Shim:   $outputExe"
Write-Host "Target: $target"
Write-Host ''
Write-Host 'The shim is not enabled in VS Code by this script.'
Write-Host 'Use Test-CodexAppServerShim.ps1 before configuring chatgpt.cliExecutable.'
