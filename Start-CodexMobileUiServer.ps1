[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ListenAddress,
    [string]$GatewayBaseUrl,
    [int]$Port = 8767,
    [string]$ServerPath = (Join-Path $PSScriptRoot 'mobile-build\CodexMobileUiServer.exe'),
    [string]$WebRoot = (Join-Path $PSScriptRoot 'mobile')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ServerPath -PathType Leaf)) { throw "Mobile UI server executable not found: $ServerPath" }
if (-not (Test-Path -LiteralPath $WebRoot -PathType Container)) { throw "Mobile web root not found: $WebRoot" }

$parsedIp = $null
if (-not [System.Net.IPAddress]::TryParse($ListenAddress, [ref]$parsedIp)) { throw "ListenAddress is not a valid IP address: $ListenAddress" }
if ($parsedIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { throw 'This prototype requires an explicit IPv4 ListenAddress.' }
if ($ListenAddress -eq '0.0.0.0') { throw '0.0.0.0 is not allowed.' }

if ([string]::IsNullOrWhiteSpace($GatewayBaseUrl)) {
    $runtimeDir = Join-Path $env:LOCALAPPDATA 'CodexApprovalNotifier\lan-gateway'
    foreach ($candidate in @(Get-ChildItem -LiteralPath $runtimeDir -Filter 'gateway-*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)) {
        try {
            $d = Get-Content -LiteralPath $candidate.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne (Get-Process -Id ([int]$d.pid) -ErrorAction SilentlyContinue)) {
                $GatewayBaseUrl = [string]$d.api
                break
            }
        }
        catch { }
    }
}

if ([string]::IsNullOrWhiteSpace($GatewayBaseUrl)) { throw 'No live LAN gateway descriptor was found. Start CodexLanGateway first or pass -GatewayBaseUrl.' }
if (-not $GatewayBaseUrl.EndsWith('/')) { $GatewayBaseUrl += '/' }

Write-Host 'Starting Codex Mobile UI Server...'
Write-Host "Listen:  $ListenAddress`:$Port"
Write-Host "Gateway: $GatewayBaseUrl"
Write-Host "Web root: $WebRoot"
Write-Host 'WARNING: prototype transport is HTTP on the trusted home LAN.'
Write-Host ''

& $ServerPath `
  --listen-address $ListenAddress `
  --port $Port `
  --gateway-base $GatewayBaseUrl `
  --web-root $WebRoot

exit $LASTEXITCODE
