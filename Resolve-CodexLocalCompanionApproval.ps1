[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('decline', 'accept')][string]$Decision,
    [Parameter(Mandatory)][string]$ExpectedCommandContains,
    [string]$CompanionDescriptorPath,
    [ValidateRange(15, 600)][int]$TimeoutSeconds = 120
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

    return Invoke-RestMethod -Uri $Uri -Method $Method -Headers $Headers -TimeoutSec 5
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
$companionPid = [int]$descriptor.pid

if (-not $api.StartsWith('http://127.0.0.1:', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Companion API is not loopback-only: $api"
}
if ($null -eq (Get-Process -Id $companionPid -ErrorAction SilentlyContinue)) {
    throw "Companion process is not running: PID $companionPid"
}
if (-not (Test-Path -LiteralPath $tokenFile -PathType Leaf)) {
    throw "Companion token file missing: $tokenFile"
}
$token = (Get-Content -LiteralPath $tokenFile -Raw -Encoding UTF8).Trim()
if ([string]::IsNullOrWhiteSpace($token)) {
    throw 'Companion token file was empty.'
}
$headers = @{ Authorization = "Bearer $token" }

Write-Host '# Codex Local Companion Approval Decision Acceptance'
Write-Host "API:        $api"
Write-Host "Thread:     $threadId"
Write-Host "Decision:   $Decision"
Write-Host "Must match: $ExpectedCommandContains"
Write-Host 'Transport:   companion HTTP API only; no direct Codex WebSocket connection'
Write-Host ''

$status = Invoke-Api -Uri ($api + 'api/status') -Method Get -Headers $headers
if (-not $status.connected) {
    throw 'Companion reports app-server disconnected.'
}
if ([string]$status.threadId -ne $threadId) {
    throw 'Companion status returned the wrong thread id.'
}
Write-Host 'Companion connected: True'
Write-Host 'Waiting for a matching pending command approval...'

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

    if ($matches.Count -gt 1) {
        Write-Host 'Matching approvals:'
        $matches | ForEach-Object { Write-Host "  handle=$($_.handle) command=$($_.command)" }
        throw 'More than one pending approval matches the expected command. Refusing to guess which handle to resolve.'
    }
    if ($matches.Count -eq 1) {
        $selected = $matches[0]
        break
    }

    Start-Sleep -Milliseconds 200
}

if ($null -eq $selected) {
    throw "No pending approval containing '$ExpectedCommandContains' appeared within $TimeoutSeconds seconds."
}

Write-Host ''
Write-Host '=== COMPANION APPROVAL SELECTED ==='
Write-Host "Handle:    $($selected.handle)"
Write-Host "Thread ID: $($selected.threadId)"
Write-Host "Turn ID:   $($selected.turnId)"
Write-Host "Item ID:   $($selected.itemId)"
Write-Host "CWD:       $($selected.cwd)"
Write-Host "Reason:    $($selected.reason)"
Write-Host "Command:   $($selected.command)"
Write-Host "Decision:  $Decision"

if ([string]$selected.threadId -ne $threadId) {
    throw 'Selected approval belongs to a different thread. No decision was sent.'
}
if (([string]$selected.command).IndexOf($ExpectedCommandContains, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
    throw 'Expected-command fence failed. No decision was sent.'
}

$handle = [string]$selected.handle
$decisionUri = $api + 'api/approvals/' + [Uri]::EscapeDataString($handle) + '/' + $Decision
Write-Host ''
Write-Host 'Expected-command fence: PASS'
Write-Host "POSTing '$Decision' to opaque companion handle..."
$result = Invoke-Api -Uri $decisionUri -Method Post -Headers $headers
if (-not $result.ok -or [string]$result.handle -ne $handle -or [string]$result.decision -ne $Decision) {
    throw 'Companion returned an unexpected decision response.'
}
Write-Host 'Companion decision response: OK'

$removed = $false
for ($i = 0; $i -lt 25; $i++) {
    $after = Invoke-Api -Uri ($api + 'api/approvals') -Method Get -Headers $headers
    $stillThere = @($after.data | Where-Object { [string]$_.handle -eq $handle })
    if ($stillThere.Count -eq 0) {
        $removed = $true
        break
    }
    Start-Sleep -Milliseconds 100
}
Write-Host "Handle removed from pending list: $removed"
if (-not $removed) {
    throw 'Resolved handle remained in the companion pending list.'
}

$staleRejected = $false
try {
    Invoke-Api -Uri $decisionUri -Method Post -Headers $headers | Out-Null
}
catch {
    $response = $_.Exception.Response
    if ($null -ne $response -and [int]$response.StatusCode -eq 409) {
        $staleRejected = $true
    }
}
Write-Host "Second use rejected with 409:      $staleRejected"
if (-not $staleRejected) {
    throw 'Companion did not reject reuse of the already-resolved approval handle.'
}

Write-Host ''
Write-Host "PASS: companion API resolved the command approval with '$Decision' using a one-time opaque handle."
if ($Decision -eq 'decline') {
    Write-Host 'Confirm VS Code reports the native approval as rejected and the command does not execute.'
}
else {
    Write-Host 'Confirm VS Code reports the command output after the native approval is accepted.'
}
