[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ThreadId,
    [string]$DescriptorPath,
    [ValidateRange(15, 600)][int]$TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'

$ApprovalMethods = @(
    'item/commandExecution/requestApproval',
    'item/fileChange/requestApproval',
    'item/permissions/requestApproval',
    'execCommandApproval',
    'applyPatchApproval'
)

function Find-LiveBridgeDescriptor {
    $runtimeDir = Join-Path $env:LOCALAPPDATA 'CodexApprovalNotifier\local-bridge'
    if (-not (Test-Path -LiteralPath $runtimeDir -PathType Container)) {
        throw "Local bridge runtime directory not found: $runtimeDir"
    }

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

    throw 'No live local-bridge descriptor was found.'
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
        $null = $Socket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult()
    }
    finally {
        $cts.Dispose()
    }
}

function Receive-WebSocketText {
    param(
        [Parameter(Mandatory)][System.Net.WebSockets.ClientWebSocket]$Socket,
        [Parameter(Mandatory)][int]$TimeoutMilliseconds
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

    $message = [ordered]@{ id = $Id; method = $Method }
    if ($null -ne $Params) { $message.params = $Params }
    Send-WebSocketText -Socket $Socket -Text ($message | ConvertTo-Json -Compress -Depth 20)
}

function Receive-JsonRpcForId {
    param(
        [Parameter(Mandatory)][System.Net.WebSockets.ClientWebSocket]$Socket,
        [Parameter(Mandatory)][int]$Id,
        [int]$TimeoutMilliseconds = 15000
    )

    $observed = @()
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $remaining = [Math]::Max(1, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        $text = Receive-WebSocketText -Socket $Socket -TimeoutMilliseconds $remaining
        $message = $text | ConvertFrom-Json -ErrorAction Stop

        if ($null -eq $message.method -and $null -ne $message.id -and [string]$message.id -eq [string]$Id) {
            return [pscustomobject]@{ Raw = $text; Message = $message; Observed = $observed }
        }

        $observed += [pscustomobject]@{ Raw = $text; Message = $message }
    }

    throw "Timed out waiting for JSON-RPC response id $Id."
}

function Test-ApprovalForThread {
    param($Message)

    if ($null -eq $Message -or [string]::IsNullOrWhiteSpace([string]$Message.method)) { return $false }
    if ($ApprovalMethods -notcontains [string]$Message.method) { return $false }

    $params = $Message.params
    $messageThreadId = if ($null -ne $params.threadId) { [string]$params.threadId } elseif ($null -ne $params.conversationId) { [string]$params.conversationId } else { '' }
    return $messageThreadId -eq $ThreadId
}

function Show-Approval {
    param($Message)

    $p = $Message.params
    Write-Host ''
    Write-Host '=== APPROVAL OBSERVED BY CLIENT #2 ==='
    Write-Host "Method:      $($Message.method)"
    Write-Host "Request ID:  $($Message.id)"

    if ($null -ne $p.threadId) { Write-Host "Thread ID:   $($p.threadId)" }
    elseif ($null -ne $p.conversationId) { Write-Host "Thread ID:   $($p.conversationId)" }
    if ($null -ne $p.turnId) { Write-Host "Turn ID:     $($p.turnId)" }
    if ($null -ne $p.itemId) { Write-Host "Item ID:     $($p.itemId)" }
    if ($null -ne $p.approvalId) { Write-Host "Approval ID: $($p.approvalId)" }
    if ($null -ne $p.callId) { Write-Host "Call ID:     $($p.callId)" }
    if ($null -ne $p.cwd) { Write-Host "CWD:         $($p.cwd)" }
    if ($null -ne $p.reason) { Write-Host "Reason:      $($p.reason)" }
    if ($null -ne $p.command) {
        $commandText = if ($p.command -is [System.Array]) { @($p.command) -join ' ' } else { [string]$p.command }
        Write-Host "Command:     $commandText"
    }
    if ($null -ne $p.grantRoot) { Write-Host "Grant root:  $($p.grantRoot)" }
    if ($null -ne $p.permissions) { Write-Host 'Permissions: present (not expanded by this watcher)' }

    Write-Host ''
    Write-Host 'NO RESPONSE WAS SENT TO THIS APPROVAL REQUEST.'
    Write-Host 'Leave the VS Code approval pending until you compare it with this output.'
}

if ([string]::IsNullOrWhiteSpace($DescriptorPath)) { $DescriptorPath = Find-LiveBridgeDescriptor }
if (-not (Test-Path -LiteralPath $DescriptorPath -PathType Leaf)) { throw "Bridge descriptor not found: $DescriptorPath" }

$descriptor = Get-Content -LiteralPath $DescriptorPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
$uri = [Uri][string]$descriptor.uri
$tokenFile = [string]$descriptor.tokenFile
$shimPid = [int]$descriptor.shimPid
$codexPid = [int]$descriptor.codexPid

if ($uri.Scheme -ne 'ws' -or $uri.Host -notin @('127.0.0.1', 'localhost', '::1')) { throw "Non-loopback bridge URI: $uri" }
if (-not (Test-Path -LiteralPath $tokenFile -PathType Leaf)) { throw "Bridge token file missing: $tokenFile" }
$token = (Get-Content -LiteralPath $tokenFile -Raw -Encoding UTF8).Trim()
if ([string]::IsNullOrWhiteSpace($token)) { throw 'Bridge token file is empty.' }

$shim = Get-CimInstance Win32_Process -Filter "ProcessId=$shimPid" -ErrorAction SilentlyContinue
$codex = Get-CimInstance Win32_Process -Filter "ProcessId=$codexPid" -ErrorAction SilentlyContinue
if ($null -eq $shim -or $null -eq $codex -or [int]$codex.ParentProcessId -ne $shimPid) { throw 'Bridge process chain is no longer valid.' }

Write-Host '# Codex Local Bridge Approval Watch'
Write-Host "Thread:     $ThreadId"
Write-Host "Shim PID:   $shimPid"
Write-Host "Codex PID:  $codexPid"
Write-Host "Listener:   $uri"
Write-Host "Timeout:    $TimeoutSeconds seconds"
Write-Host 'Mode:       observe approval only; no approval response is sent'
Write-Host ''

$socket = New-Object System.Net.WebSockets.ClientWebSocket
$subscribed = $false
$approval = $null
try {
    $socket.Options.SetRequestHeader('Authorization', "Bearer $token")
    $connectCts = New-Object System.Threading.CancellationTokenSource
    $connectCts.CancelAfter(10000)
    try { $null = $socket.ConnectAsync($uri, $connectCts.Token).GetAwaiter().GetResult() }
    finally { $connectCts.Dispose() }

    $initParams = [ordered]@{
        clientInfo = [ordered]@{
            name = 'codex-approval-notifier-approval-watch'
            title = 'Codex Approval Notifier Approval Watch'
            version = '0.1.0'
        }
        capabilities = [ordered]@{ experimentalApi = $true }
    }
    Send-JsonRpcRequest -Socket $socket -Id 31001 -Method 'initialize' -Params $initParams
    $init = Receive-JsonRpcForId -Socket $socket -Id 31001
    if ($null -ne $init.Message.error -or $null -eq $init.Message.result) { throw "initialize failed: $($init.Raw)" }
    Send-WebSocketText -Socket $socket -Text '{"method":"initialized"}'

    Send-JsonRpcRequest -Socket $socket -Id 31002 -Method 'thread/read' -Params ([ordered]@{ threadId = $ThreadId; includeTurns = $false })
    $read = Receive-JsonRpcForId -Socket $socket -Id 31002
    if ($null -ne $read.Message.error -or [string]$read.Message.result.thread.id -ne $ThreadId) { throw "thread/read failed: $($read.Raw)" }
    Write-Host "Thread preview: $($read.Message.result.thread.preview)"

    Send-JsonRpcRequest -Socket $socket -Id 31003 -Method 'thread/resume' -Params ([ordered]@{ threadId = $ThreadId })
    $resume = Receive-JsonRpcForId -Socket $socket -Id 31003
    if ($null -ne $resume.Message.error -or [string]$resume.Message.result.thread.id -ne $ThreadId) { throw "thread/resume failed: $($resume.Raw)" }
    $subscribed = $true
    Write-Host 'Client #2 subscribed: True'

    foreach ($entry in @($resume.Observed)) {
        if (Test-ApprovalForThread -Message $entry.Message) {
            $approval = $entry.Message
            break
        }
    }

    if ($null -eq $approval) {
        Write-Host 'Waiting for an approval request from this thread...'
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while ([DateTime]::UtcNow -lt $deadline) {
            $remaining = [Math]::Max(1, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            try {
                $text = Receive-WebSocketText -Socket $socket -TimeoutMilliseconds $remaining
            }
            catch [System.OperationCanceledException] { break }
            catch [System.Threading.Tasks.TaskCanceledException] { break }

            $message = $text | ConvertFrom-Json -ErrorAction Stop
            if (Test-ApprovalForThread -Message $message) {
                $approval = $message
                break
            }
        }
    }

    if ($null -eq $approval) {
        throw "No approval request for thread $ThreadId was observed within $TimeoutSeconds seconds."
    }

    Show-Approval -Message $approval
}
finally {
    if ($subscribed -and $socket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
        try {
            Send-JsonRpcRequest -Socket $socket -Id 31999 -Method 'thread/unsubscribe' -Params ([ordered]@{ threadId = $ThreadId })
            $null = Receive-JsonRpcForId -Socket $socket -Id 31999 -TimeoutMilliseconds 5000
        }
        catch { }
    }

    try {
        if ($socket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $closeCts = New-Object System.Threading.CancellationTokenSource
            $closeCts.CancelAfter(1000)
            try { $null = $socket.CloseOutputAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'approval watch complete', $closeCts.Token).GetAwaiter().GetResult() }
            catch { }
            finally { $closeCts.Dispose() }
        }
    }
    catch { }
    $socket.Dispose()
}
