[CmdletBinding()]
param(
    [string]$ThreadId = '00000000-0000-0000-0000-000000000001'
)

$ErrorActionPreference = 'Stop'

$runtimeDir = Join-Path $env:LOCALAPPDATA 'CodexApprovalNotifier\local-bridge'
New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null

$current = Get-Process -Id $PID -ErrorAction Stop
$currentStart = [DateTimeOffset]$current.StartTime
$createdBeforeThisProcess = $currentStart.AddSeconds(-5)
$createdAfterThisProcessSameSecond = $currentStart.AddMilliseconds(250)
$descriptorPath = Join-Path $runtimeDir "bridge-$PID.json"
$tokenPath = Join-Path $runtimeDir "bridge-$PID.token"

if (Test-Path -LiteralPath $descriptorPath) { throw "Refusing to overwrite existing bridge descriptor: $descriptorPath" }
if (Test-Path -LiteralPath $tokenPath) { throw "Refusing to overwrite existing bridge token: $tokenPath" }

function Write-SyntheticDescriptor([DateTimeOffset]$CreatedAt) {
    $fake = [ordered]@{
        version = 1
        shimPid = $PID
        codexPid = $PID
        uri = 'ws://127.0.0.1:1'
        tokenFile = $tokenPath
        target = 'synthetic-pid-reuse-test'
        createdAt = $CreatedAt.ToString('o')
    }
    $fake | ConvertTo-Json -Compress | Set-Content -LiteralPath $descriptorPath -Encoding UTF8
}

try {
    Set-Content -LiteralPath $tokenPath -Value 'synthetic-token-must-not-be-used' -Encoding ASCII

    Write-Host '# Codex Runtime Descriptor Identity Acceptance'
    Write-Host "Synthetic descriptor: $descriptorPath"
    Write-Host "Recorded PID:         $PID"
    Write-Host "Process started:      $($currentStart.ToString('o'))"
    Write-Host ''

    # Case 1: descriptor is older than the process. Both supported consumers must
    # reject it before trusting or contacting the fake WebSocket endpoint.
    Write-SyntheticDescriptor -CreatedAt $createdBeforeThisProcess

    $selectorRejected = $false
    try {
        & (Join-Path $PSScriptRoot 'Select-CodexLiveThread.ps1') -DescriptorPath $descriptorPath | Out-Null
    }
    catch {
        if ($_.Exception.Message -match 'started after the descriptor was created') { $selectorRejected = $true }
    }
    Write-Host "Thread selector rejected reused PID identity: $selectorRejected"
    if (-not $selectorRejected) { throw 'Thread selector did not reject the synthetic stale/reused-PID descriptor.' }

    $launcherRejected = $false
    try {
        & (Join-Path $PSScriptRoot 'Start-CodexLocalCompanion.ps1') -ThreadId $ThreadId -DescriptorPath $descriptorPath | Out-Null
    }
    catch {
        if ($_.Exception.Message -match 'started after the descriptor was created') { $launcherRejected = $true }
    }
    Write-Host "Companion launcher rejected reused PID identity: $launcherRejected"
    if (-not $launcherRejected) { throw 'Companion launcher did not reject the synthetic stale/reused-PID descriptor.' }

    # Case 2: descriptor is created later in the same second as the process start.
    # The identity fence must preserve sub-second precision. Reaching the fake
    # WebSocket/token stage proves identity validation succeeded; connection failure
    # is expected because ws://127.0.0.1:1 is deliberately unreachable.
    Write-SyntheticDescriptor -CreatedAt $createdAfterThisProcessSameSecond

    $selectorIdentityPassed = $false
    try {
        & (Join-Path $PSScriptRoot 'Select-CodexLiveThread.ps1') -DescriptorPath $descriptorPath | Out-Null
    }
    catch {
        if ($_.Exception.Message -notmatch 'started after the descriptor was created') {
            $selectorIdentityPassed = $true
        }
    }
    Write-Host "Thread selector preserved same-second precision: $selectorIdentityPassed"
    if (-not $selectorIdentityPassed) { throw 'Thread selector lost same-second descriptor timestamp precision.' }

    $launcherIdentityPassed = $false
    try {
        # A successful identity check proceeds into CodexLocalCompanion. The
        # synthetic ws://127.0.0.1:1 endpoint then fails in the companion process;
        # that external nonzero exit is expected and does not constitute an
        # identity-validation failure.
        & (Join-Path $PSScriptRoot 'Start-CodexLocalCompanion.ps1') -ThreadId $ThreadId -DescriptorPath $descriptorPath | Out-Null
        $launcherIdentityPassed = $true
    }
    catch {
        if ($_.Exception.Message -match 'started after the descriptor was created') {
            $launcherIdentityPassed = $false
        }
        else {
            throw
        }
    }
    Write-Host "Companion launcher preserved same-second precision: $launcherIdentityPassed"
    if (-not $launcherIdentityPassed) { throw 'Companion launcher lost same-second descriptor timestamp precision.' }

    Write-Host ''
    Write-Host 'PASS: bridge consumers reject reused-PID descriptors while preserving same-second timestamp precision.' -ForegroundColor Green
    Write-Host 'The fake WebSocket endpoint was never accepted as a live Codex session.'
}
finally {
    Remove-Item -LiteralPath $descriptorPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tokenPath -Force -ErrorAction SilentlyContinue
}
