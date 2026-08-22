[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExpectedCommandContains,
    [string]$CompanionDescriptorPath,
    [ValidateRange(5, 3600)][int]$ExpectedApprovalTtlSeconds = 5,
    [ValidateRange(15, 180)][int]$TimeoutSeconds = 45
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

function Invoke-Api {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    Invoke-RestMethod -Uri $Uri -Method $Method -Headers $Headers -TimeoutSec 5
}

if ([string]::IsNullOrWhiteSpace($CompanionDescriptorPath)) {
    $CompanionDescriptorPath = Find-LiveCompanionDescriptor
}

$descriptor = Get-Content -LiteralPath $CompanionDescriptorPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
$api = [string]$descriptor.api
$tokenFile = [string]$descriptor.tokenFile
$threadId = [string]$descriptor.threadId
$companionPid = [int]$descriptor.pid
$ttl = [int]$descriptor.approvalTtlSeconds

if ($ttl -ne $ExpectedApprovalTtlSeconds) {
    throw "Companion approval TTL mismatch. Expected $ExpectedApprovalTtlSeconds, got $ttl."
}
if ($null -eq (Get-Process -Id $companionPid -ErrorAction SilentlyContinue)) {
    throw "Companion process is not running: PID $companionPid"
}
if (-not $api.StartsWith('http://127.0.0.1:', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Companion API is not loopback-only: $api"
}
if (-not (Test-Path -LiteralPath $tokenFile -PathType Leaf)) {
    throw "Companion token file missing: $tokenFile"
}
$token = (Get-Content -LiteralPath $tokenFile -Raw -Encoding UTF8).Trim()
if ([string]::IsNullOrWhiteSpace($token)) { throw 'Companion token file was empty.' }
$headers = @{ Authorization = "Bearer $token" }

Write-Host '# Codex Local Companion Approval Expiry Acceptance'
Write-Host "API:          $api"
Write-Host "Thread:       $threadId"
Write-Host "Approval TTL: $ttl seconds"
Write-Host "Must match:   $ExpectedCommandContains"
Write-Host ''

$statusBefore = Invoke-Api -Uri ($api + 'api/status') -Method Get -Headers $headers
if (-not $statusBefore.connected) { throw 'Companion is not connected to Codex app-server.' }
$expiredBefore = [int]$statusBefore.expiredDeclineCount

Write-Host 'Trigger one native command approval in Codex now and do NOT approve/deny it.'
Write-Host 'Waiting for matching approval...'

$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$selected = $null
while ([DateTime]::UtcNow -lt $deadline) {
    $approvals = Invoke-Api -Uri ($api + 'api/approvals') -Method Get -Headers $headers
    $matches = @($approvals.data | Where-Object {
        [string]$_.threadId -eq $threadId -and
        -not [string]::IsNullOrWhiteSpace([string]$_.handle) -and
        -not [string]::IsNullOrWhiteSpace([string]$_.command) -and
        ([string]$_.command).IndexOf($ExpectedCommandContains, [StringComparison]::OrdinalIgnoreCase) -ge 0
    })

    if ($matches.Count -gt 1) { throw 'More than one matching pending approval exists; refusing to guess.' }
    if ($matches.Count -eq 1) {
        $selected = $matches[0]
        break
    }
    Start-Sleep -Milliseconds 150
}

if ($null -eq $selected) {
    throw "No pending approval containing '$ExpectedCommandContains' appeared within $TimeoutSeconds seconds."
}

$handle = [string]$selected.handle
$expiresAt = [DateTimeOffset]::Parse([string]$selected.expiresAt)
Write-Host "Captured handle: $handle"
Write-Host "Expires at:      $($expiresAt.ToString('o'))"
Write-Host 'Waiting for automatic expiry decline...'

$expired = $false
$counterAdvanced = $false
$expiryDeadline = [DateTime]::UtcNow.AddSeconds($ExpectedApprovalTtlSeconds + 12)
while ([DateTime]::UtcNow -lt $expiryDeadline) {
    $approvals = Invoke-Api -Uri ($api + 'api/approvals') -Method Get -Headers $headers
    $stillThere = @($approvals.data | Where-Object { [string]$_.handle -eq $handle })
    $status = Invoke-Api -Uri ($api + 'api/status') -Method Get -Headers $headers
    if ($stillThere.Count -eq 0) { $expired = $true }
    if ([int]$status.expiredDeclineCount -gt $expiredBefore) { $counterAdvanced = $true }
    if ($expired -and $counterAdvanced) { break }
    Start-Sleep -Milliseconds 150
}

Write-Host "Handle removed after TTL:        $expired"
Write-Host "Expired decline counter advanced: $counterAdvanced"
if (-not ($expired -and $counterAdvanced)) {
    throw 'Expired approval was not proven to auto-decline and leave the pending list.'
}

$staleRejected = $false
try {
    Invoke-Api -Uri ($api + 'api/approvals/' + [Uri]::EscapeDataString($handle) + '/accept') -Method Post -Headers $headers | Out-Null
}
catch {
    $response = $_.Exception.Response
    if ($null -ne $response -and [int]$response.StatusCode -eq 409) {
        $staleRejected = $true
    }
}
Write-Host "Expired handle accept rejected 409: $staleRejected"
if (-not $staleRejected) {
    throw 'Expired approval handle was not rejected as stale/resolved.'
}

Write-Host ''
Write-Host 'PASS: expired command approval was automatically declined and its one-time handle became stale.' -ForegroundColor Green
Write-Host 'Confirm VS Code reports the native approval as rejected/declined and the command did not execute.'
