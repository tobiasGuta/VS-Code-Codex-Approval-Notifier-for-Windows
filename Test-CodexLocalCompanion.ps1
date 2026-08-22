[CmdletBinding()]
param(
    [string]$CompanionDescriptorPath
)

$ErrorActionPreference = 'Stop'

function Find-LiveCompanionDescriptor {
    $runtimeDir = Join-Path $env:LOCALAPPDATA 'CodexApprovalNotifier\companion'
    if (-not (Test-Path -LiteralPath $runtimeDir -PathType Container)) {
        throw "Companion runtime directory not found: $runtimeDir"
    }

    foreach ($candidate in @(Get-ChildItem -LiteralPath $runtimeDir -Filter 'companion-*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending)) {
        try {
            $d = Get-Content -LiteralPath $candidate.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne (Get-Process -Id ([int]$d.pid) -ErrorAction SilentlyContinue)) {
                return $candidate.FullName
            }
        }
        catch { }
    }

    throw 'No live companion descriptor was found.'
}

if ([string]::IsNullOrWhiteSpace($CompanionDescriptorPath)) {
    $CompanionDescriptorPath = Find-LiveCompanionDescriptor
}
if (-not (Test-Path -LiteralPath $CompanionDescriptorPath -PathType Leaf)) {
    throw "Companion descriptor not found: $CompanionDescriptorPath"
}

$descriptor = Get-Content -LiteralPath $CompanionDescriptorPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
$api = [string]$descriptor.api
$tokenFile = [string]$descriptor.tokenFile
$threadId = [string]$descriptor.threadId

if (-not $api.StartsWith('http://127.0.0.1:', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Companion API is not loopback-only: $api"
}
if (-not (Test-Path -LiteralPath $tokenFile -PathType Leaf)) {
    throw "Companion token file missing: $tokenFile"
}
$token = (Get-Content -LiteralPath $tokenFile -Raw -Encoding UTF8).Trim()
if ([string]::IsNullOrWhiteSpace($token)) { throw 'Companion token file was empty.' }

Write-Host '# Codex Local Companion API Acceptance'
Write-Host "Descriptor: $CompanionDescriptorPath"
Write-Host "API:        $api"
Write-Host "Thread:     $threadId"
Write-Host 'Auth:       bearer token (not displayed)'
Write-Host ''

$unauthorizedRejected = $false
try {
    Invoke-RestMethod -Uri ($api + 'api/status') -Method Get -TimeoutSec 5 | Out-Null
}
catch {
    $response = $_.Exception.Response
    if ($null -ne $response -and [int]$response.StatusCode -eq 401) {
        $unauthorizedRejected = $true
    }
}
Write-Host "Unauthenticated request rejected: $unauthorizedRejected"
if (-not $unauthorizedRejected) { throw 'Companion API accepted an unauthenticated request.' }

$headers = @{ Authorization = "Bearer $token" }
$status = Invoke-RestMethod -Uri ($api + 'api/status') -Method Get -Headers $headers -TimeoutSec 5
if (-not $status.connected) { throw 'Companion reports app-server disconnected.' }
if ([string]$status.threadId -ne $threadId) { throw 'Companion status returned the wrong thread id.' }
Write-Host 'Authorized status:               OK'
Write-Host "App-server connected:            $($status.connected)"
Write-Host "Pending count:                   $($status.pendingCount)"

$approvals = Invoke-RestMethod -Uri ($api + 'api/approvals') -Method Get -Headers $headers -TimeoutSec 5
$data = @($approvals.data)
Write-Host 'Authorized approvals list:       OK'
Write-Host "Approvals returned:              $($data.Count)"

foreach ($approval in $data) {
    if ([string]$approval.threadId -ne $threadId) { throw 'Companion exposed an approval from a different thread.' }
    if ([string]::IsNullOrWhiteSpace([string]$approval.handle)) { throw 'Companion exposed an approval without a local handle.' }
    Write-Host "  handle=$($approval.handle) command=$($approval.command)"
}

Write-Host ''
Write-Host 'PASS: loopback companion API is authenticated, connected to the proven live thread, and exposes only local approval handles.'
Write-Host 'This test did not send accept/decline or expose any LAN listener.'
