[CmdletBinding()]
param(
    [string]$DescriptorPath
)

$ErrorActionPreference = 'Stop'

function Find-LiveBridgeDescriptor {
    $runtimeDir = Join-Path $env:LOCALAPPDATA 'CodexApprovalNotifier\local-bridge'
    if (-not (Test-Path -LiteralPath $runtimeDir -PathType Container)) {
        throw 'Remote approvals bridge is not running. Open VS Code with the Codex bridge enabled.'
    }
    foreach ($candidate in @(Get-ChildItem -LiteralPath $runtimeDir -Filter 'bridge-*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)) {
        try {
            $d = Get-Content -LiteralPath $candidate.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne (Get-Process -Id ([int]$d.shimPid) -ErrorAction SilentlyContinue) -and
                $null -ne (Get-Process -Id ([int]$d.codexPid) -ErrorAction SilentlyContinue)) {
                return $candidate.FullName
            }
        } catch { }
    }
    throw 'No live Codex bridge was found. Open VS Code and a Codex chat, then try again.'
}

function Send-Text($Socket, [string]$Text) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $segment = [ArraySegment[byte]]::new($bytes)
    $cts = [Threading.CancellationTokenSource]::new(10000)
    try { $null = $Socket.SendAsync($segment, [Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult() }
    finally { $cts.Dispose() }
}

function Receive-Text($Socket, [int]$TimeoutMs) {
    $buffer = New-Object byte[] 65536
    $segment = [ArraySegment[byte]]::new($buffer)
    $memory = [IO.MemoryStream]::new()
    try {
        do {
            $cts = [Threading.CancellationTokenSource]::new($TimeoutMs)
            try { $r = $Socket.ReceiveAsync($segment, $cts.Token).GetAwaiter().GetResult() }
            finally { $cts.Dispose() }
            if ($r.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) { throw 'Codex bridge closed while selecting the live thread.' }
            if ($r.MessageType -ne [Net.WebSockets.WebSocketMessageType]::Text) { throw 'Unexpected binary message from Codex bridge.' }
            if ($r.Count -gt 0) { $memory.Write($buffer, 0, $r.Count) }
        } while (-not $r.EndOfMessage)
        return [Text.Encoding]::UTF8.GetString($memory.ToArray())
    } finally { $memory.Dispose() }
}

function Send-Request($Socket, [int]$Id, [string]$Method, $Params) {
    $obj = [ordered]@{ id = $Id; method = $Method }
    if ($null -ne $Params) { $obj.params = $Params }
    Send-Text $Socket ($obj | ConvertTo-Json -Compress -Depth 20)
}

function Receive-ForId($Socket, [int]$Id, [int]$TimeoutMs = 15000) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    $observed = @()
    while ([DateTime]::UtcNow -lt $deadline) {
        $remaining = [Math]::Max(1, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        $raw = Receive-Text $Socket $remaining
        $msg = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $msg.method -and $null -ne $msg.id -and [string]$msg.id -eq [string]$Id) {
            return [pscustomobject]@{ Message = $msg; Observed = $observed }
        }
        $observed += $msg
    }
    throw "Timed out waiting for Codex response id $Id."
}

if ([string]::IsNullOrWhiteSpace($DescriptorPath)) { $DescriptorPath = Find-LiveBridgeDescriptor }
$descriptor = Get-Content -LiteralPath $DescriptorPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
$uri = [Uri][string]$descriptor.uri
$tokenFile = [string]$descriptor.tokenFile
if ($uri.Scheme -ne 'ws' -or $uri.Host -notin @('127.0.0.1','localhost','::1')) { throw 'Bridge descriptor is not loopback-only.' }
if (-not (Test-Path -LiteralPath $tokenFile -PathType Leaf)) { throw 'Bridge capability token is missing.' }
$token = (Get-Content -LiteralPath $tokenFile -Raw -Encoding UTF8).Trim()
if ([string]::IsNullOrWhiteSpace($token)) { throw 'Bridge capability token is empty.' }

$socket = [Net.WebSockets.ClientWebSocket]::new()
$subscribed = $null
try {
    $socket.Options.SetRequestHeader('Authorization', "Bearer $token")
    $cts = [Threading.CancellationTokenSource]::new(10000)
    try { $null = $socket.ConnectAsync($uri, $cts.Token).GetAwaiter().GetResult() }
    finally { $cts.Dispose() }

    Send-Request $socket 61001 'initialize' ([ordered]@{
        clientInfo = [ordered]@{ name='codex-approval-notifier-thread-selector'; title='Codex Approval Notifier Thread Selector'; version='0.1.0' }
        capabilities = [ordered]@{ experimentalApi=$true }
    })
    $init = Receive-ForId $socket 61001
    if ($null -ne $init.Message.error) { throw "Codex initialize failed: $($init.Message.error.message)" }
    Send-Text $socket '{"method":"initialized"}'

    Send-Request $socket 61002 'thread/loaded/list' ([ordered]@{})
    $loaded = Receive-ForId $socket 61002
    if ($null -ne $loaded.Message.error) { throw "Could not list loaded Codex threads: $($loaded.Message.error.message)" }
    $ids = @($loaded.Message.result.data | ForEach-Object { [string]$_ })
    if ($ids.Count -eq 0) { throw 'No Codex chat is currently loaded. Open a Codex chat and try again.' }

    $resumable = @()
    $requestId = 61100
    foreach ($id in $ids) {
        $requestId++
        Send-Request $socket $requestId 'thread/read' ([ordered]@{ threadId=$id; includeTurns=$false })
        $read = Receive-ForId $socket $requestId
        if ($null -ne $read.Message.error) { continue }

        $requestId++
        Send-Request $socket $requestId 'thread/resume' ([ordered]@{ threadId=$id })
        $resume = Receive-ForId $socket $requestId
        if ($null -ne $resume.Message.error) { continue }
        if ([string]$resume.Message.result.thread.id -ne $id) { continue }
        $subscribed = $id

        $requestId++
        Send-Request $socket $requestId 'thread/unsubscribe' ([ordered]@{ threadId=$id })
        $unsub = Receive-ForId $socket $requestId
        $subscribed = $null
        if ($null -ne $unsub.Message.error -or [string]$unsub.Message.result.status -ne 'unsubscribed') {
            throw "Could not cleanly unsubscribe while validating thread $id."
        }
        $resumable += $id
    }

    if ($resumable.Count -eq 0) { throw 'No resumable live Codex chat was found. Open the Codex chat you want to control and try again.' }
    if ($resumable.Count -gt 1) { throw "More than one resumable Codex chat is active. Close the extra Codex chats and try again." }

    # Success output is intentionally one line so the tray app can consume it safely.
    [Console]::Out.WriteLine($resumable[0])
}
finally {
    if ($null -ne $subscribed -and $socket.State -eq [Net.WebSockets.WebSocketState]::Open) {
        try {
            Send-Request $socket 61999 'thread/unsubscribe' ([ordered]@{ threadId=$subscribed })
            $null = Receive-ForId $socket 61999 3000
        } catch { }
    }
    try { $socket.Dispose() } catch { }
}
