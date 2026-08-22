[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'gateway-build')
)

$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot 'CodexLanGateway.cs'
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
    throw "Gateway source not found: $source"
}

$cscCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }

if ($cscCandidates.Count -eq 0) {
    throw 'C# compiler csc.exe from .NET Framework v4 was not found.'
}
$csc = $cscCandidates[0]

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$output = Join-Path $OutputDirectory 'CodexLanGateway.exe'

& $csc /nologo /target:exe /optimize+ /out:$output /r:System.Web.Extensions.dll $source
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output -PathType Leaf)) {
    throw "Gateway compilation failed with exit code $LASTEXITCODE."
}

Write-Host 'Codex LAN Gateway built.'
Write-Host "Compiler: $csc"
Write-Host "Output:   $output"
