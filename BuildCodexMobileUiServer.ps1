[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'mobile-build')
)

$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'CodexMobileUiServer.cs'
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Mobile UI server source not found: $source" }

$cscCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
if ($cscCandidates.Count -eq 0) { throw 'C# compiler csc.exe from .NET Framework v4 was not found.' }
$csc = $cscCandidates[0]

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$output = Join-Path $OutputDirectory 'CodexMobileUiServer.exe'
& $csc /nologo /target:exe /optimize+ /out:$output $source
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output -PathType Leaf)) {
    throw "Mobile UI server compilation failed with exit code $LASTEXITCODE."
}

Write-Host 'Codex Mobile UI Server built.'
Write-Host "Compiler: $csc"
Write-Host "Output:   $output"
