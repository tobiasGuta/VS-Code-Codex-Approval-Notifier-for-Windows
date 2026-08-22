[CmdletBinding()]
param(
    [string]$ThreadId = '00000000-0000-0000-0000-000000000001'
)

$ErrorActionPreference = 'Stop'

$runtimeDir = Join-Path $env:LOCALAPPDATA 'CodexApprovalNotifier\local-bridge'
New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null

$current = Get-Process -Id $PID -ErrorAction Stop
$createdBeforeThisProcess = ([DateTimeOffset]$current.StartTime).AddSeconds(-5)
$descriptorPath = Join-Path $runtimeDir "bridge-$PID.json"
$tokenPath = Join-Path $runtimeDir "bridge-$PID.token"

if (Test-Path -LiteralPath $descriptorPath) { throw "Refusing to overwrite existing bridge descriptor: $descriptorPath" }
if (Test-Path -LiteralPath $tokenPath) { throw "Refusing to overwrite existing bridge token: $tokenPath" }

$fake = [ordered]@{
    version = 1
    shimPid = $PID
    codexPid = $PID
    uri = 'ws://127.0.0.1:1'
    tokenFile = $tokenPath
    target = 'synthetic-pid-reuse-test'
    createdAt = $createdBeforeThisProcess.ToString('o')
}

try {
    $fake | ConvertTo-Json -Compress | Set-Content -LiteralPath $descriptorPath -Encoding UTF8
    Set-Content -LiteralPath $tokenPath -Value 'synthetic-token-must-not-be-used' -Encoding ASCII

    Write-Host '# Codex Runtime Descriptor Identity Acceptance'
    Write-Host "Synthetic descriptor: $descriptorPath"
    Write-Host "Recorded PID:         $PID"
    Write-Host "Process started:      $(([DateTimeOffset]$current.StartTime).ToString('o'))"
    Write-Host "Descriptor createdAt: $($createdBeforeThisProcess.ToString('o'))"
    Write-Host ''

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

    Write-Host ''
    Write-Host 'PASS: supported bridge consumers fail closed on stale descriptors whose PIDs have been reused.' -ForegroundColor Green
    Write-Host 'The fake WebSocket endpoint was never trusted or contacted.'
}
finally {
    Remove-Item -LiteralPath $descriptorPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tokenPath -Force -ErrorAction SilentlyContinue
}
