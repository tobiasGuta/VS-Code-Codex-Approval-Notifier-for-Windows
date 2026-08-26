[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$cscCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }

if ($cscCandidates.Count -eq 0) { throw 'C# compiler csc.exe from .NET Framework v4 was not found.' }
$csc = $cscCandidates[0]
$frameworkDir = Split-Path -Parent $csc
$webExtensions = Join-Path $frameworkDir 'System.Web.Extensions.dll'
if (-not (Test-Path -LiteralPath $webExtensions -PathType Leaf)) { throw "System.Web.Extensions.dll not found: $webExtensions" }

$outDir = Join-Path $PSScriptRoot 'file-change-tests-build'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$output = Join-Path $outDir 'CodexFileChangeApprovalLogicTests.exe'
Remove-Item -LiteralPath $output -Force -ErrorAction SilentlyContinue

Write-Host "Compiler: $csc"
Write-Host "Output:   $output"
Write-Host ''

& $csc /nologo /target:exe /main:TestCodexFileChangeApprovalLogic /optimize+ /out:$output /reference:$webExtensions `
    (Join-Path $PSScriptRoot 'CodexLocalCompanion.cs') `
    (Join-Path $PSScriptRoot 'TestCodexFileChangeApprovalLogic.cs')

if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output -PathType Leaf)) {
    throw "Test compilation failed with exit code $LASTEXITCODE."
}

Write-Host 'Compilation OK.'
Write-Host ''
& $output
$testExit = $LASTEXITCODE
Write-Host ''
if ($testExit -ne 0) { throw "File-change approval logic tests exited with code $testExit." }
Write-Host 'PASS  Test-CodexFileChangeApprovalLogic: all tests passed.' -ForegroundColor Green
