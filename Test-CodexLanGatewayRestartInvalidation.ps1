[CmdletBinding()]
param(
    [string]$CompanionDescriptorPath,
    [string]$GatewayPath = (Join-Path $PSScriptRoot 'gateway-build\CodexLanGateway.exe'),
    [int]$TimeoutSeconds = 10
)

$ErrorActionPreference = 'Stop'

function Find-LiveCompanionDescriptor {
    $runtimeDir = Join-Path $env:LOCALAPPDATA 'CodexApprovalNotifier\companion'
    foreach ($candidate in @(Get-ChildItem -LiteralPath $runtimeDir -Filter 'companion-*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending)) {
        try {
            $d = Get-Content -LiteralPath $candidate.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne (Get-Process -Id ([int]$d.pid) -ErrorAction SilentlyContinue)) { return $candidate.FullName }
        }
        catch { }
    }
    throw 'No live companion descriptor was found.'
}

function Get-FreeLoopbackPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    }
    finally { $listener.Stop() }
}

function Start-Gateway {
    param([int]$Port)

    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $GatewayPath
    $start.Arguments = "--companion-descriptor `"$CompanionDescriptorPath`" --listen-address 127.0.0.1 --port $Port"
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $start
    if (-not $p.Start()) { throw 'Failed to start gateway.' }
    $stderrTask = $p.StandardError.ReadToEndAsync()

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $code = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($p.HasExited) {
            $detail = $stderrTask.GetAwaiter().GetResult()
            throw "Gateway exited during startup. $detail"
        }
        $read = $p.StandardOutput.ReadLineAsync()
        if (-not $read.Wait(500)) { continue }
        $line = $read.Result
        if ($null -eq $line) { continue }
        if ($line.StartsWith('Pairing code:', [StringComparison]::OrdinalIgnoreCase)) {
            $code = $line.Substring('Pairing code:'.Length).Trim()
            break
        }
    }
    if ($code -notmatch '^\d{6}$') {
        try { if (-not $p.HasExited) { $p.Kill(); $p.WaitForExit(3000) | Out-Null } } catch { }
        throw 'Gateway did not provide a valid 6-digit pairing code.'
    }

    $base = "http://127.0.0.1:$Port/"
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            Invoke-RestMethod -Uri ($base + 'pairing/status') -Method Get -TimeoutSec 2 | Out-Null
            return [pscustomobject]@{ Process=$p; Base=$base; Code=$code; StderrTask=$stderrTask }
        }
        catch { Start-Sleep -Milliseconds 100 }
    }

    try { if (-not $p.HasExited) { $p.Kill(); $p.WaitForExit(3000) | Out-Null } } catch { }
    throw 'Gateway HTTP listener did not become ready.'
}

function Stop-Gateway($gateway) {
    if ($null -eq $gateway) { return }
    try {
        if (-not $gateway.Process.HasExited) {
            $gateway.Process.Kill()
            $gateway.Process.WaitForExit(3000) | Out-Null
        }
    }
    catch { }
    try { $gateway.Process.Dispose() } catch { }
}

function Pair-Gateway($gateway) {
    return Invoke-RestMethod -Uri ($gateway.Base + 'pair') -Method Post -Headers @{ 'X-Pairing-Code' = $gateway.Code } -TimeoutSec 5
}

if (-not (Test-Path -LiteralPath $GatewayPath -PathType Leaf)) { throw "Gateway executable not found: $GatewayPath" }
$GatewayPath = (Resolve-Path -LiteralPath $GatewayPath).Path
if ([string]::IsNullOrWhiteSpace($CompanionDescriptorPath)) { $CompanionDescriptorPath = Find-LiveCompanionDescriptor }
if (-not (Test-Path -LiteralPath $CompanionDescriptorPath -PathType Leaf)) { throw "Companion descriptor not found: $CompanionDescriptorPath" }
$CompanionDescriptorPath = (Resolve-Path -LiteralPath $CompanionDescriptorPath).Path

$port = Get-FreeLoopbackPort
$first = $null
$second = $null
try {
    Write-Host '# Codex LAN Gateway Restart Invalidation Acceptance'
    Write-Host "Companion: $CompanionDescriptorPath"
    Write-Host "Loopback:  127.0.0.1:$port"
    Write-Host ''

    $first = Start-Gateway -Port $port
    $paired1 = Pair-Gateway $first
    if (-not $paired1.ok -or [string]::IsNullOrWhiteSpace([string]$paired1.deviceToken)) { throw 'First gateway pairing failed.' }
    $oldToken = [string]$paired1.deviceToken
    $oldCode = [string]$first.Code
    $oldHeaders = @{ Authorization = "Bearer $oldToken" }
    $status1 = Invoke-RestMethod -Uri ($first.Base + 'api/status') -Headers $oldHeaders -Method Get -TimeoutSec 5
    if (-not $status1.connected) { throw 'First gateway session was not connected.' }
    Write-Host 'First session paired and authorized: PASS'

    Stop-Gateway $first
    $first = $null

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $second = Start-Gateway -Port $port
        if ([string]$second.Code -ne $oldCode) { break }
        Stop-Gateway $second
        $second = $null
    }
    if ($null -eq $second) { throw 'Could not obtain a fresh pairing code distinct from the prior session after restart.' }

    $oldTokenRejected = $false
    try {
        Invoke-RestMethod -Uri ($second.Base + 'api/status') -Headers $oldHeaders -Method Get -TimeoutSec 5 | Out-Null
    }
    catch {
        if ($null -ne $_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 401) { $oldTokenRejected = $true }
    }
    Write-Host "Old device token rejected after restart: $oldTokenRejected"
    if (-not $oldTokenRejected) { throw 'A device token from the prior gateway process still authorized the restarted gateway.' }

    $oldCodeRejected = $false
    try {
        Invoke-RestMethod -Uri ($second.Base + 'pair') -Method Post -Headers @{ 'X-Pairing-Code' = $oldCode } -TimeoutSec 5 | Out-Null
    }
    catch {
        if ($null -ne $_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 401) { $oldCodeRejected = $true }
    }
    Write-Host "Old pairing code rejected after restart:  $oldCodeRejected"
    if (-not $oldCodeRejected) { throw 'The prior gateway pairing code was accepted by the new gateway session.' }

    $paired2 = Pair-Gateway $second
    if (-not $paired2.ok -or [string]::IsNullOrWhiteSpace([string]$paired2.deviceToken)) { throw 'Fresh gateway pairing failed.' }
    $newToken = [string]$paired2.deviceToken
    if ([string]::Equals($oldToken, $newToken, [StringComparison]::Ordinal)) { throw 'Gateway restart reused the previous device token.' }
    $status2 = Invoke-RestMethod -Uri ($second.Base + 'api/status') -Headers @{ Authorization = "Bearer $newToken" } -Method Get -TimeoutSec 5
    if (-not $status2.connected) { throw 'Fresh gateway token did not authorize the restarted session.' }
    Write-Host 'Fresh pairing after restart:              PASS'
    Write-Host 'Fresh device token differs:              PASS'
    Write-Host ''
    Write-Host 'PASS: gateway restart invalidates prior device-token and pairing-code state while fresh pairing still works.' -ForegroundColor Green
}
finally {
    Stop-Gateway $first
    Stop-Gateway $second
}
