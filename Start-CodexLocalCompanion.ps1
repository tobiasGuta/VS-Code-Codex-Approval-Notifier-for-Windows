[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ThreadId,
    [int]$Port = 8765,
    [string]$CompanionPath = (Join-Path $PSScriptRoot 'companion-build\CodexLocalCompanion.exe'),
    [string]$DescriptorPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $CompanionPath -PathType Leaf)) {
    throw "Companion executable not found: $CompanionPath"
}
$CompanionPath = (Resolve-Path -LiteralPath $CompanionPath).Path

if ([string]::IsNullOrWhiteSpace($DescriptorPath)) {
    $runtimeDir = Join-Path $env:LOCALAPPDATA 'CodexApprovalNotifier\local-bridge'
    $candidates = @(Get-ChildItem -LiteralPath $runtimeDir -Filter 'bridge-*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending)

    foreach ($candidate in $candidates) {
        try {
            $d = Get-Content -LiteralPath $candidate.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne (Get-Process -Id ([int]$d.shimPid) -ErrorAction SilentlyContinue) -and
                $null -ne (Get-Process -Id ([int]$d.codexPid) -ErrorAction SilentlyContinue)) {
                $DescriptorPath = $candidate.FullName
                break
            }
        }
        catch { }
    }
}

if ([string]::IsNullOrWhiteSpace($DescriptorPath) -or -not (Test-Path -LiteralPath $DescriptorPath -PathType Leaf)) {
    throw 'No live local-bridge descriptor was found.'
}
$DescriptorPath = (Resolve-Path -LiteralPath $DescriptorPath).Path

Write-Host 'Starting Codex Local Companion...'
Write-Host "Thread:     $ThreadId"
Write-Host "Bridge:     $DescriptorPath"
Write-Host "HTTP port:  $Port"
Write-Host ''

& $CompanionPath --descriptor $DescriptorPath --thread $ThreadId --port $Port
exit $LASTEXITCODE
