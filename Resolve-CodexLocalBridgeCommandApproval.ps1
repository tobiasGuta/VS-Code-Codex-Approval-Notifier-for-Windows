[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ThreadId,
    [Parameter(Mandatory)][ValidateSet('decline', 'accept')][string]$Decision,
    [Parameter(Mandatory)][string]$ExpectedCommandContains,
    [string]$DescriptorPath,
    [ValidateRange(15, 600)][int]$TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
$ApprovalMethod = 'item/commandExecution/requestApproval'

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

function Test-CommandApprovalForThread {
    param($Message)

    if ($null -eq $Message) { return $false }
    if ([string]$Message.method -ne $ApprovalMethod) { return $false }
    if ([string]$Message.params.threadId -ne $ThreadId) { return $false }
    if ($null -eq $Message.id) { return $false }
    return $true
}

function Get-CommandText {
    param($Approval)

    if ($null -eq $Approval.params.command) { return '' }
    if ($Approval.params.command -is [System.Array]) { return (@($Approval.params.command) -join ' ') }
    return [string]$Approval.params.command
}

function Show-Approval {
    param($Approval)

    $p = $Approval.params
    Write-Host ''
    Write-Host '=== COMMAND APPROVAL SELECTED ==='
    Write-Host "Method:      $($Approval.method)"
    Write-Host "Request ID:  $($Approval.id)"
    Write-Host "Thread ID:   $($p.threadId)"
    Write-Host "Turn ID:     $($p.turnId)"
    Write-Host "Item ID:     $($p.itemId)"
    if ($null -ne $p.approvalId) { Write-Host "Approval ID: $($p.approvalId)" }
    Write-Host "CWD:         $($p.cwd)"
    Write-Host "Reason:      $($p.reason)"
    Write-Host "Command:     $(Get-CommandText -Approval $Approval)"
    Write-Host "Decision:    $Decision"
}

function Wait-ForResolvedNotification {
    param(
        [Parameter(Mandatory)][System.Net.WebSockets.ClientWebSocket]$Socket,
        [Parameter(Mandatory)]$RequestId,
        [int]$TimeoutMilliseconds = 10000
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $remaining = [Math]::Max(1, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        try {
            $text = Receive-WebSocketText -Socket $Socket -TimeoutMilliseconds $remaining
        }
        catch [System.OperationCanceledException] {
            return $false
        }

        $message = $text | ConvertFrom-Json -ErrorAction Stop
        if ([string]$message.method -eq 'serverRequest/resolved' -and
            [string]$message.params.threadId -eq $ThreadId -and
            [string]$message.params.requestId -eq [string]$RequestId) {
            return $true
        }
    }

    return $false
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

Write-Host '# Codex Local Bridge Command Approval Decision Test'
Write-Host "Thread:     $ThreadId"
Write-Host "Decision:   $Decision"
Write-Host "Must match: $ExpectedCommandContains"
Write-Host "Shim PID:   $shimPid"
Write-Host "Codex PID:  $codexPid"
Write-Host "Listener:   $uri"
Write-Host 'Scope:      modern command approval only; exact thread; expected-command fence'
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
            name = 'codex-approval-notifier-command-decision-test'
            title = 'Codex Approval Notifier Command Decision Test'
            version = '0.1.0'
        }
        capabilities = [ordered]@{ experimentalApi = $true }
    }
    Send-JsonRpcRequest -Socket $socket -Id 41001 -Method 'initialize' -Params $initParams
    $init = Receive-JsonRpcForId -Socket $socket -Id 41001
    if ($null -ne $init.Message.error -or $null -eq $init.Message.result) { throw "initialize failed: $($init.Raw)" }
    Send-WebSocketText -Socket $socket -Text '{"method":"initialized"}'

    Send-JsonRpcRequest -Socket $socket -Id 41002 -Method 'thread/read' -Params ([ordered]@{ threadId = $ThreadId; includeTurns = $false })
    $read = Receive-JsonRpcForId -Socket $socket -Id 41002
    if ($null -ne $read.Message.error -or [string]$read.Message.result.thread.id -ne $ThreadId) { throw "thread/read failed: $($read.Raw)" }
    Write-Host "Thread preview: $($read.Message.result.thread.preview)"

    Send-JsonRpcRequest -Socket $socket -Id 41003 -Method 'thread/resume' -Params ([ordered]@{ threadId = $ThreadId })
    $resume = Receive-JsonRpcForId -Socket $socket -Id 41003
    if ($null -ne $resume.Message.error -or [string]$resume.Message.result.thread.id -ne $ThreadId) { throw "thread/resume failed: $($resume.Raw)" }
    $subscribed = $true
    Write-Host 'Client #2 subscribed: True'

    foreach ($entry in @($resume.Observed)) {
        if (Test-CommandApprovalForThread -Message $entry.Message) {
            $approval = $entry.Message
            break
        }
    }

    if ($null -eq $approval) {
        Write-Host 'Waiting for a modern command approval request from this thread...'
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while ([DateTime]::UtcNow -lt $deadline) {
            $remaining = [Math]::Max(1, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            try {
                $text = Receive-WebSocketText -Socket $socket -TimeoutMilliseconds $remaining
            }
            catch [System.OperationCanceledException] { break }

            $message = $text | ConvertFrom-Json -ErrorAction Stop
            if (Test-CommandApprovalForThread -Message $message) {
                $approval = $message
                break
            }
        }
    }

    if ($null -eq $approval) {
        throw "No modern command approval for thread $ThreadId was observed within $TimeoutSeconds seconds."
    }

    $commandText = Get-CommandText -Approval $approval
    Show-Approval -Approval $approval

    if ([string]::IsNullOrWhiteSpace($commandText)) {
        throw 'Approval did not contain a command. Refusing to send a decision.'
    }
    if ($commandText.IndexOf($ExpectedCommandContains, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "Command fence failed. Expected command to contain '$ExpectedCommandContains'. No decision was sent."
    }

    $response = [ordered]@{
        id = $approval.id
        result = [ordered]@{
            decision = $Decision
        }
    } | ConvertTo-Json -Compress -Depth 8

    Write-Host ''
    Write-Host 'Command fence: PASS'
    Write-Host "Sending semantic decision '$Decision' for request id $($approval.id)..."
    Send-WebSocketText -Socket $socket -Text $response

    $resolved = Wait-ForResolvedNotification -Socket $socket -RequestId $approval.id
    Write-Host "serverRequest/resolved observed: $resolved"
    if (-not $resolved) {
        throw 'Decision was sent, but matching serverRequest/resolved was not observed within 10 seconds.'
    }

    Write-Host ''
    Write-Host "PASS: client #2 resolved the live VS Code command approval with decision '$Decision'."
    if ($Decision -eq 'decline') {
        Write-Host 'The command should not execute. Confirm the VS Code approval disappears and the turn reports the denial.'
    }
    else {
        Write-Host 'Confirm VS Code observes the approval resolution and the harmless expected command executes.'
    }
}
finally {
    if ($subscribed -and $socket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
        try {
            Send-JsonRpcRequest -Socket $socket -Id 41999 -Method 'thread/unsubscribe' -Params ([ordered]@{ threadId = $ThreadId })
            $null = Receive-JsonRpcForId -Socket $socket -Id 41999 -TimeoutMilliseconds 5000
        }
        catch { }
    }

    try {
        if ($socket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $closeCts = New-Object System.Threading.CancellationTokenSource
            $closeCts.CancelAfter(1000)
            try { $null = $socket.CloseOutputAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'command decision test complete', $closeCts.Token).GetAwaiter().GetResult() }
            catch { }
            finally { $closeCts.Dispose() }
        }
    }
    catch { }
    $socket.Dispose()
}
