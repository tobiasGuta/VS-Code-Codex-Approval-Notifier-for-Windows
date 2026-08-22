[CmdletBinding()]
param(
    [string]$DescriptorPath,
    [string]$ThreadId
)

$ErrorActionPreference = 'Stop'

function Find-LiveBridgeDescriptor {
    $runtimeDir = Join-Path $env:LOCALAPPDATA 'CodexApprovalNotifier\local-bridge'
    if (-not (Test-Path -LiteralPath $runtimeDir -PathType Container)) {
        throw "Local bridge runtime directory not found: $runtimeDir`r`nStart VS Code with the shim in local-bridge mode first."
    }

    $candidates = @(Get-ChildItem -LiteralPath $runtimeDir -Filter 'bridge-*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending)

    foreach ($candidate in $candidates) {
        try {
            $descriptor = Get-Content -LiteralPath $candidate.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            $shim = Get-Process -Id ([int]$descriptor.shimPid) -ErrorAction SilentlyContinue
            $codex = Get-Process -Id ([int]$descriptor.codexPid) -ErrorAction SilentlyContinue
            if ($null -ne $shim -and $null -ne $codex) {
                return $candidate.FullName
            }
        }
        catch { }
    }

    throw "No live local-bridge descriptor was found under $runtimeDir."
}

function Send-WebSocketText {
    param(
        [Parameter(Mandatory)][System.Net.WebSockets.ClientWebSocket]$Socket,
        [Parameter(Mandatory)][string]$Text
    )

    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $segment = [ArraySegment[byte]]::new($bytes)
    $cts = New-Object System.Threading.CancellationTokenSource
    $cts.CancelAfter(10000)
    try {
        $null = $Socket.SendAsync(
            $segment,
            [System.Net.WebSockets.WebSocketMessageType]::Text,
            $true,
            $cts.Token
        ).GetAwaiter().GetResult()
    }
    finally {
        $cts.Dispose()
    }
}

function Receive-WebSocketText {
    param(
        [Parameter(Mandatory)][System.Net.WebSockets.ClientWebSocket]$Socket,
        [int]$TimeoutMilliseconds = 15000
    )

    $buffer = New-Object byte[] 65536
    $segment = [ArraySegment[byte]]::new($buffer)
    $memory = New-Object IO.MemoryStream
    try {
        do {
            $cts = New-Object System.Threading.CancellationTokenSource
            $cts.CancelAfter($TimeoutMilliseconds)
            try {
                $result = $Socket.ReceiveAsync($segment, $cts.Token).GetAwaiter().GetResult()
            }
            finally {
                $cts.Dispose()
            }

            if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                throw 'Codex local bridge WebSocket closed unexpectedly.'
            }
            if ($result.MessageType -ne [System.Net.WebSockets.WebSocketMessageType]::Text) {
                throw "Unexpected WebSocket message type: $($result.MessageType)"
            }
            if ($result.Count -gt 0) {
                $memory.Write($buffer, 0, $result.Count)
            }
        } while (-not $result.EndOfMessage)

        return [Text.Encoding]::UTF8.GetString($memory.ToArray())
    }
    finally {
        $memory.Dispose()
    }
}

function Send-JsonRpcRequest {
    param(
        [Parameter(Mandatory)][System.Net.WebSockets.ClientWebSocket]$Socket,
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][string]$Method,
        $Params
    )

    $message = [ordered]@{
        id = $Id
        method = $Method
    }
    if ($null -ne $Params) {
        $message.params = $Params
    }

    Send-WebSocketText -Socket $Socket -Text ($message | ConvertTo-Json -Compress -Depth 20)
}

function Receive-JsonRpcForId {
    param(
        [Parameter(Mandatory)][System.Net.WebSockets.ClientWebSocket]$Socket,
        [Parameter(Mandatory)][int]$Id
    )

    # Use a native PowerShell array here rather than List[object]. Some
    # PowerShell/.NET combinations throw "Argument types do not match" when a
    # generic List[object] is array-wrapped inside a PSCustomObject property.
    $observed = @()
    for ($attempt = 0; $attempt -lt 200; $attempt++) {
        $text = Receive-WebSocketText -Socket $Socket
        try {
            $message = $text | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw "Received non-JSON WebSocket payload:`r`n$text"
        }

        # A response/error has an id but no method. Server->client requests also
        # carry ids, so require method to be absent before matching our request.
        if ($null -eq $message.method -and $null -ne $message.id -and [string]$message.id -eq [string]$Id) {
            return [pscustomobject]@{
                Raw = $text
                Message = $message
                Observed = $observed
            }
        }

        $observed += [pscustomobject]@{
            Raw = $text
            Message = $message
        }
    }

    throw "Did not receive JSON-RPC response id $Id within the message limit."
}

function Get-PendingServerRequests {
    param([object[]]$Observed)

    return @($Observed | Where-Object {
        $message = $_.Message
        $null -ne $message.id -and
        -not [string]::IsNullOrWhiteSpace([string]$message.method)
    })
}

if (-not ('System.Net.WebSockets.ClientWebSocket' -as [type])) {
    throw 'System.Net.WebSockets.ClientWebSocket is unavailable in this PowerShell/.NET runtime.'
}

if ([string]::IsNullOrWhiteSpace($DescriptorPath)) {
    $DescriptorPath = Find-LiveBridgeDescriptor
}
if (-not (Test-Path -LiteralPath $DescriptorPath -PathType Leaf)) {
    throw "Bridge descriptor not found: $DescriptorPath"
}
$DescriptorPath = (Resolve-Path -LiteralPath $DescriptorPath).Path
$descriptor = Get-Content -LiteralPath $DescriptorPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop

$uri = [string]$descriptor.uri
$tokenFile = [string]$descriptor.tokenFile
$shimPid = [int]$descriptor.shimPid
$codexPid = [int]$descriptor.codexPid
$parsedUri = [Uri]$uri

if ($parsedUri.Scheme -ne 'ws' -or $parsedUri.Host -notin @('127.0.0.1', 'localhost', '::1')) {
    throw "Descriptor contains a non-loopback WebSocket URI: $uri"
}
if (-not (Test-Path -LiteralPath $tokenFile -PathType Leaf)) {
    throw "Bridge capability-token file not found: $tokenFile"
}
$token = (Get-Content -LiteralPath $tokenFile -Raw -Encoding UTF8).Trim()
if ([string]::IsNullOrWhiteSpace($token)) {
    throw 'Bridge capability-token file was empty.'
}

$shimProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$shimPid" -ErrorAction SilentlyContinue
$codexProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$codexPid" -ErrorAction SilentlyContinue
if ($null -eq $shimProcess -or $null -eq $codexProcess) {
    throw 'Bridge descriptor refers to a process that is no longer running.'
}
if ([int]$codexProcess.ParentProcessId -ne $shimPid) {
    throw "Codex PID $codexPid is not a child of shim PID $shimPid."
}
if ([string]$codexProcess.CommandLine -notmatch '(?i)--listen\s+ws://127\.0\.0\.1:0') {
    throw 'Codex child is not using the expected loopback WebSocket transport.'
}
if ([string]$codexProcess.CommandLine -notmatch '(?i)--ws-auth\s+capability-token') {
    throw 'Codex child is not using capability-token WebSocket authentication.'
}

Write-Host '# Codex Local Bridge Live-Thread Subscription Acceptance'
Write-Host "Descriptor: $DescriptorPath"
Write-Host "Shim PID:   $shimPid"
Write-Host "Codex PID:  $codexPid"
Write-Host "Listener:   $uri"
Write-Host 'Mode:       read-only thread discovery + subscribe/unsubscribe; no turn start or approval response'
Write-Host ''

$socket = New-Object System.Net.WebSockets.ClientWebSocket
$subscribedThreadId = $null
try {
    $socket.Options.SetRequestHeader('Authorization', "Bearer $token")
    $connectCts = New-Object System.Threading.CancellationTokenSource
    $connectCts.CancelAfter(10000)
    try {
        $null = $socket.ConnectAsync($parsedUri, $connectCts.Token).GetAwaiter().GetResult()
    }
    finally {
        $connectCts.Dispose()
    }

    if ($socket.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
        throw "Second client did not reach Open state: $($socket.State)"
    }

    $initializeParams = [ordered]@{
        clientInfo = [ordered]@{
            name = 'codex-approval-notifier-live-thread-test'
            title = 'Codex Approval Notifier Live Thread Test'
            version = '0.1.0'
        }
        capabilities = [ordered]@{
            experimentalApi = $true
        }
    }
    Send-JsonRpcRequest -Socket $socket -Id 21001 -Method 'initialize' -Params $initializeParams
    $initialize = Receive-JsonRpcForId -Socket $socket -Id 21001
    if ($null -ne $initialize.Message.error -or $null -eq $initialize.Message.result) {
        throw "Second-client initialize failed: $($initialize.Raw)"
    }
    Send-WebSocketText -Socket $socket -Text '{"method":"initialized"}'
    Write-Host 'Second client initialize:        OK'

    Send-JsonRpcRequest -Socket $socket -Id 21002 -Method 'thread/loaded/list' -Params ([ordered]@{})
    $loaded = Receive-JsonRpcForId -Socket $socket -Id 21002
    if ($null -ne $loaded.Message.error -or $null -eq $loaded.Message.result.data) {
        throw "thread/loaded/list failed: $($loaded.Raw)"
    }

    $loadedIds = @($loaded.Message.result.data | ForEach-Object { [string]$_ })
    Write-Host "Loaded threads visible:          $($loadedIds.Count)"

    if ($loadedIds.Count -eq 0) {
        throw 'No thread is currently loaded in VS Code Codex. Open an existing Codex chat (or start a harmless chat), wait for it to load, then rerun this script.'
    }

    if ([string]::IsNullOrWhiteSpace($ThreadId)) {
        if ($loadedIds.Count -ne 1) {
            Write-Host 'Loaded thread IDs:'
            $loadedIds | ForEach-Object { Write-Host "  $_" }
            throw 'Multiple Codex threads are loaded. Rerun with -ThreadId <id> so the test does not guess which live thread to subscribe to.'
        }
        $ThreadId = $loadedIds[0]
    }
    elseif ($loadedIds -notcontains $ThreadId) {
        throw "Requested thread is not currently loaded: $ThreadId"
    }

    Write-Host "Selected thread:                 $ThreadId"

    Send-JsonRpcRequest -Socket $socket -Id 21003 -Method 'thread/read' -Params ([ordered]@{
        threadId = $ThreadId
        includeTurns = $false
    })
    $read = Receive-JsonRpcForId -Socket $socket -Id 21003
    if ($null -ne $read.Message.error -or $null -eq $read.Message.result.thread) {
        throw "thread/read failed: $($read.Raw)"
    }
    if ([string]$read.Message.result.thread.id -ne $ThreadId) {
        throw "thread/read returned a different thread id: $($read.Message.result.thread.id)"
    }

    $statusType = [string]$read.Message.result.thread.status.type
    $preview = [string]$read.Message.result.thread.preview
    if ($preview.Length -gt 100) {
        $preview = $preview.Substring(0, 100) + '...'
    }
    Write-Host 'thread/read:                     OK'
    Write-Host "Thread status:                   $statusType"
    Write-Host "Thread preview:                  $preview"

    # For a running thread, thread/resume rejoins that existing runtime rather
    # than creating a second app-server writer. No overrides are supplied.
    Send-JsonRpcRequest -Socket $socket -Id 21004 -Method 'thread/resume' -Params ([ordered]@{
        threadId = $ThreadId
    })
    $resume = Receive-JsonRpcForId -Socket $socket -Id 21004
    if ($null -ne $resume.Message.error -or $null -eq $resume.Message.result.thread) {
        throw "thread/resume failed: $($resume.Raw)"
    }
    if ([string]$resume.Message.result.thread.id -ne $ThreadId) {
        throw 'thread/resume returned the wrong thread.'
    }
    $subscribedThreadId = $ThreadId

    $pendingRequests = Get-PendingServerRequests -Observed $resume.Observed
    Write-Host 'thread/resume subscription:      OK'
    Write-Host "Pending server requests replayed: $($pendingRequests.Count)"
    if ($pendingRequests.Count -gt 0) {
        $pendingRequests | ForEach-Object {
            Write-Host "  request id=$($_.Message.id) method=$($_.Message.method)"
        }
        Write-Host '  (not answered by this read-only test)'
    }

    Send-JsonRpcRequest -Socket $socket -Id 21005 -Method 'thread/unsubscribe' -Params ([ordered]@{
        threadId = $ThreadId
    })
    $unsubscribe = Receive-JsonRpcForId -Socket $socket -Id 21005
    if ($null -ne $unsubscribe.Message.error -or $null -eq $unsubscribe.Message.result.status) {
        throw "thread/unsubscribe failed: $($unsubscribe.Raw)"
    }

    $unsubscribeStatus = [string]$unsubscribe.Message.result.status
    if ($unsubscribeStatus -ne 'unsubscribed') {
        throw "Expected thread/unsubscribe status 'unsubscribed', got '$unsubscribeStatus'."
    }
    $subscribedThreadId = $null

    Write-Host "thread/unsubscribe:              $unsubscribeStatus"
    Write-Host ''
    Write-Host 'PASS: authenticated client #2 read and joined the same live VS Code Codex thread, then cleanly unsubscribed.'
    Write-Host 'No new thread, turn, command, file change, approval response, or LAN listener was created by this test.'
}
finally {
    if ($null -ne $subscribedThreadId -and $socket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
        try {
            Send-JsonRpcRequest -Socket $socket -Id 21999 -Method 'thread/unsubscribe' -Params ([ordered]@{
                threadId = $subscribedThreadId
            })
            $null = Receive-JsonRpcForId -Socket $socket -Id 21999
        }
        catch { }
    }

    try {
        if ($socket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $closeCts = New-Object System.Threading.CancellationTokenSource
            $closeCts.CancelAfter(1500)
            try {
                $null = $socket.CloseOutputAsync(
                    [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
                    'live-thread test complete',
                    $closeCts.Token
                ).GetAwaiter().GetResult()
            }
            catch { }
            finally { $closeCts.Dispose() }
        }
    }
    catch { }
    $socket.Dispose()
}
