[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ThreadId,
    [Parameter(Mandatory)][string]$ExpectedCommandContains,
    [string]$BridgeDescriptorPath,
    [string]$CompanionPath = (Join-Path $PSScriptRoot 'companion-build\CodexLocalCompanion.exe'),
    [ValidateRange(15, 300)][int]$TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'

function Find-LiveBridgeDescriptor {
    $runtimeDir = Join-Path $env:LOCALAPPDATA 'CodexApprovalNotifier\local-bridge'
    foreach ($candidate in @(Get-ChildItem -LiteralPath $runtimeDir -Filter 'bridge-*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending)) {
        try {
            $d = Get-Content -LiteralPath $candidate.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne (Get-Process -Id ([int]$d.shimPid) -ErrorAction SilentlyContinue) -and
                $null -ne (Get-Process -Id ([int]$d.codexPid) -ErrorAction SilentlyContinue)) {
                return $candidate.FullName
            }
        }
        catch { }
    }
    throw 'No live bridge descriptor was found.'
}

function Get-FreeLoopbackPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try { $listener.Start(); return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port }
    finally { $listener.Stop() }
}

function Wait-Until {
    param([scriptblock]$Condition,[string]$Description,[int]$Timeout=$TimeoutSeconds)
    $deadline = [DateTime]::UtcNow.AddSeconds($Timeout)
    do {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 150
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $Description."
}

function Start-Companion {
    param([int]$Port)
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $CompanionPath
    $start.Arguments = "--descriptor `"$BridgeDescriptorPath`" --thread `"$ThreadId`" --port $Port --approval-ttl-seconds 300"
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $start
    if (-not $p.Start()) { throw 'Failed to start companion.' }
    $stderrTask = $p.StandardError.ReadToEndAsync()

    $runtimeDir = Join-Path $env:LOCALAPPDATA 'CodexApprovalNotifier\companion'
    $descriptor = Join-Path $runtimeDir ("companion-{0}.json" -f $p.Id)
    Wait-Until -Description 'companion descriptor' -Condition { Test-Path -LiteralPath $descriptor -PathType Leaf }
    $d = Get-Content -LiteralPath $descriptor -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $token = (Get-Content -LiteralPath ([string]$d.tokenFile) -Raw -Encoding UTF8).Trim()
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'Companion token was empty.' }
    return [pscustomobject]@{ Process=$p; Api=[string]$d.api; Token=$token; Descriptor=$descriptor; StderrTask=$stderrTask }
}

function Stop-Companion($companion) {
    if ($null -eq $companion) { return }
    try {
        if (-not $companion.Process.HasExited) {
            $companion.Process.Kill()
            $companion.Process.WaitForExit(3000) | Out-Null
        }
    }
    catch { }
    try { $companion.Process.Dispose() } catch { }
}

function Invoke-CompanionApi {
    param($companion,[string]$Path,[string]$Method='GET')
    return Invoke-RestMethod -Uri ($companion.Api + $Path.TrimStart('/')) -Method $Method -Headers @{ Authorization = "Bearer $($companion.Token)" } -TimeoutSec 5
}

function Wait-MatchingApproval {
    param($companion)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $approvals = Invoke-CompanionApi -companion $companion -Path 'api/approvals'
        $matches = @($approvals.data | Where-Object {
            [string]$_.threadId -eq $ThreadId -and
            -not [string]::IsNullOrWhiteSpace([string]$_.handle) -and
            ([string]$_.command).IndexOf($ExpectedCommandContains, [StringComparison]::OrdinalIgnoreCase) -ge 0
        })
        if ($matches.Count -gt 1) { throw 'More than one matching approval was visible; refusing to guess.' }
        if ($matches.Count -eq 1) { return $matches[0] }
        Start-Sleep -Milliseconds 150
    }
    throw "No matching approval containing '$ExpectedCommandContains' appeared."
}

if (-not (Test-Path -LiteralPath $CompanionPath -PathType Leaf)) { throw "Companion executable not found: $CompanionPath" }
$CompanionPath = (Resolve-Path -LiteralPath $CompanionPath).Path
if ([string]::IsNullOrWhiteSpace($BridgeDescriptorPath)) { $BridgeDescriptorPath = Find-LiveBridgeDescriptor }
if (-not (Test-Path -LiteralPath $BridgeDescriptorPath -PathType Leaf)) { throw "Bridge descriptor not found: $BridgeDescriptorPath" }
$BridgeDescriptorPath = (Resolve-Path -LiteralPath $BridgeDescriptorPath).Path

$port = Get-FreeLoopbackPort
$first = $null
$second = $null
try {
    Write-Host '# Codex Local Companion Restart Invalidation Acceptance'
    Write-Host "Thread: $ThreadId"
    Write-Host "Match:  $ExpectedCommandContains"
    Write-Host ''

    $first = Start-Companion -Port $port
    Write-Host 'First companion started.'
    Write-Host 'Trigger one native command approval in Codex now and do NOT approve/deny it.'
    $oldApproval = Wait-MatchingApproval $first
    $oldHandle = [string]$oldApproval.handle
    if ([string]::IsNullOrWhiteSpace($oldHandle)) { throw 'Old approval handle was empty.' }
    Write-Host "Captured old handle: $oldHandle"

    Stop-Companion $first
    $first = $null
    Start-Sleep -Milliseconds 300

    $second = Start-Companion -Port $port
    Write-Host 'Second companion started after restart.'

    $oldHandleRejected = $false
    try {
        Invoke-CompanionApi -companion $second -Path ("api/approvals/{0}/accept" -f $oldHandle) -Method POST | Out-Null
    }
    catch {
        if ($null -ne $_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 409) { $oldHandleRejected = $true }
    }
    Write-Host "Old approval handle rejected by new companion: $oldHandleRejected"
    if (-not $oldHandleRejected) { throw 'A handle issued by the prior companion process remained usable after restart.' }

    Write-Host 'Waiting briefly to see whether Codex replays the still-pending native request to the new companion...'
    $newApproval = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ([DateTime]::UtcNow -lt $deadline -and $null -eq $newApproval) {
        $approvals = Invoke-CompanionApi -companion $second -Path 'api/approvals'
        $matches = @($approvals.data | Where-Object {
            ([string]$_.command).IndexOf($ExpectedCommandContains, [StringComparison]::OrdinalIgnoreCase) -ge 0
        })
        if ($matches.Count -gt 0) { $newApproval = $matches[0]; break }
        Start-Sleep -Milliseconds 200
    }

    if ($null -ne $newApproval) {
        $newHandle = [string]$newApproval.handle
        Write-Host "Replayed request received with new handle: $newHandle"
        if ([string]::Equals($oldHandle, $newHandle, [StringComparison]::Ordinal)) { throw 'Companion restart reused the old opaque handle.' }
        Write-Host 'Fresh handle differs from old handle: PASS'
    }
    else {
        Write-Host 'Codex did not replay the unresolved request to the restarted companion within 5 seconds; this is acceptable for invalidation.'
    }

    Write-Host ''
    Write-Host 'PASS: companion restart invalidates prior opaque approval handles.' -ForegroundColor Green
}
finally {
    Stop-Companion $first
    Stop-Companion $second
}
