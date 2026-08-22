[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ListenAddress,
    [int]$Port = 8766,
    [string]$CompanionDescriptorPath,
    [string]$GatewayPath = (Join-Path $PSScriptRoot 'gateway-build\CodexLanGateway.exe')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $GatewayPath -PathType Leaf)) {
    throw "Gateway executable not found: $GatewayPath"
}

if ([string]::IsNullOrWhiteSpace($CompanionDescriptorPath)) {
    $runtimeDir = Join-Path $env:LOCALAPPDATA 'CodexApprovalNotifier\companion'
    $candidates = @(Get-ChildItem -LiteralPath $runtimeDir -Filter 'companion-*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending)
    foreach ($candidate in $candidates) {
        try {
            $d = Get-Content -LiteralPath $candidate.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne (Get-Process -Id ([int]$d.pid) -ErrorAction SilentlyContinue)) {
                $CompanionDescriptorPath = $candidate.FullName
                break
            }
        }
        catch { }
    }
}

if ([string]::IsNullOrWhiteSpace($CompanionDescriptorPath) -or -not (Test-Path -LiteralPath $CompanionDescriptorPath -PathType Leaf)) {
    throw 'No live companion descriptor was found. Start CodexLocalCompanion first or pass -CompanionDescriptorPath explicitly.'
}

$parsedIp = $null
if (-not [System.Net.IPAddress]::TryParse($ListenAddress, [ref]$parsedIp)) {
    throw "ListenAddress is not a valid IP address: $ListenAddress"
}
if ($parsedIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
    throw 'This prototype requires an explicit IPv4 ListenAddress.'
}
if ($ListenAddress -eq '0.0.0.0') {
    throw '0.0.0.0 is not allowed. Specify the exact private IPv4 address for the intended LAN interface.'
}

Write-Host 'Starting Codex LAN Gateway...'
Write-Host "Listen:     $ListenAddress`:$Port"
Write-Host "Companion:  $CompanionDescriptorPath"
Write-Host 'Pairing:    one-time 6-digit code, 5-minute expiry'
Write-Host 'WARNING:    prototype transport is HTTP on the trusted home LAN.'
Write-Host ''

& $GatewayPath `
    --companion-descriptor $CompanionDescriptorPath `
    --listen-address $ListenAddress `
    --port $Port

exit $LASTEXITCODE
