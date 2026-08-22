[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'tray-build')
)

$ErrorActionPreference = 'Stop'

$sources = @(
    (Join-Path $PSScriptRoot 'CodexRemoteTray.cs'),
    (Join-Path $PSScriptRoot 'QrCodeV4.cs')
)
foreach ($source in $sources) {
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Tray source not found: $source"
    }
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
$output = Join-Path $OutputDirectory 'CodexRemoteTray.exe'

& $csc /nologo /target:winexe /optimize+ /out:$output `
    /r:System.Windows.Forms.dll `
    /r:System.Drawing.dll `
    /r:System.Web.Extensions.dll `
    $sources

if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output -PathType Leaf)) {
    throw "Tray compilation failed with exit code $LASTEXITCODE."
}

Write-Host 'Codex Remote Approvals tray app built.'
Write-Host "Compiler: $csc"
Write-Host "Output:   $output"
