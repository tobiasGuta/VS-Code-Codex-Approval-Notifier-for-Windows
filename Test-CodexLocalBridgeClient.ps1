[CmdletBinding()]
param(
    [string]$DescriptorPath
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
    $json = $message | ConvertTo-Json -Compress -Depth 16
    Send-WebSocketText -Socket $Socket -Text $json
}

function Receive-JsonRpcForId {
    param(
        [Parameter(Mandatory)][System.Net.WebSockets.ClientWebSocket]$Socket,
        [Parameter(Mandatory)][int]$Id
    )

    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        $text = Receive-WebSocketText -Socket $Socket
        try {
            $message = $text | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw "Received non-JSON WebSocket payload:`r`n$text"
        }

        if ($null -ne $message.id -and [string]$message.id -eq [string]$Id) {
            return [pscustomobject]@{
                Raw = $text
                Message = $message
            }
        }
    }

    throw "Did not receive JSON-RPC response id $Id within the message limit."
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
if ($null -eq $shimProcess) {
    throw "Descriptor shim PID is not running: $shimPid"
}
if ($null -eq $codexProcess) {
    throw "Descriptor Codex PID is not running: $codexPid"
}
if ([int]$codexProcess.ParentProcessId -ne $shimPid) {
    throw "Codex PID $codexPid is not a child of shim PID $shimPid."
}
if ([string]$codexProcess.CommandLine -notmatch '(?i)--listen\s+ws://127\.0\.0\.1:0') {
    throw "Codex child is not a loopback WebSocket app-server as expected:`r`n$($codexProcess.CommandLine)"
}
if ([string]$codexProcess.CommandLine -notmatch '(?i)--ws-auth\s+capability-token') {
    throw 'Codex child is not using capability-token WebSocket authentication.'
}

$listenerVerified = $false
try {
    $listener = Get-NetTCPConnection -State Listen -LocalPort $parsedUri.Port -ErrorAction Stop |
        Where-Object { [int]$_.OwningProcess -eq $codexPid } |
        Select-Object -First 1
    $listenerVerified = $null -ne $listener
}
catch { }
if (-not $listenerVerified) {
    throw "Could not verify that Codex PID $codexPid owns loopback listener port $($parsedUri.Port)."
}

Write-Host '# Codex Local Bridge Second-Client Acceptance'
Write-Host "Descriptor: $DescriptorPath"
Write-Host "Shim PID:   $shimPid"
Write-Host "Codex PID:  $codexPid"
Write-Host "Listener:   $uri"
Write-Host 'Auth:       capability-token (token not displayed)'
Write-Host ''

$socket = New-Object System.Net.WebSockets.ClientWebSocket
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
    Write-Host 'Second client authenticated:     True'

    $initializeParams = [ordered]@{
        clientInfo = [ordered]@{
            name = 'codex-approval-notifier-local-bridge-test'
            title = 'Codex Approval Notifier Local Bridge Test'
            version = '0.1.0'
        }
        capabilities = [ordered]@{
            experimentalApi = $true
        }
    }
    Send-JsonRpcRequest -Socket $socket -Id 1001 -Method 'initialize' -Params $initializeParams
    $initialize = Receive-JsonRpcForId -Socket $socket -Id 1001
    if ($null -ne $initialize.Message.error -or $null -eq $initialize.Message.result) {
        throw "Second-client initialize failed: $($initialize.Raw)"
    }
    Send-WebSocketText -Socket $socket -Text '{"method":"initialized"}'
    Write-Host 'Second client initialize:       OK'

    Send-JsonRpcRequest -Socket $socket -Id 1002 -Method 'config/read' -Params ([ordered]@{ includeLayers = $false })
    $config = Receive-JsonRpcForId -Socket $socket -Id 1002
    if ($null -ne $config.Message.error -or $null -eq $config.Message.result.config) {
        throw "Second-client config/read failed: $($config.Raw)"
    }
    Write-Host 'Second client config/read:      OK'

    Send-JsonRpcRequest -Socket $socket -Id 1003 -Method 'thread/loaded/list' -Params ([ordered]@{})
    $threads = Receive-JsonRpcForId -Socket $socket -Id 1003
    if ($null -ne $threads.Message.error -or $null -eq $threads.Message.result.data) {
        throw "Second-client thread/loaded/list failed: $($threads.Raw)"
    }
    $threadCount = @($threads.Message.result.data).Count
    Write-Host 'Second client loaded-thread RPC: OK'
    Write-Host "Loaded threads visible:          $threadCount"
    Write-Host ''
    Write-Host 'PASS: VS Code bridge client #1 and this authenticated local client #2 are sharing one Codex app-server process.'
    Write-Host 'No thread mutation, turn start, approval response, or LAN listener was used by this test.'
}
finally {
    try {
        if ($socket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $closeCts = New-Object System.Threading.CancellationTokenSource
            $closeCts.CancelAfter(1500)
            try {
                $null = $socket.CloseOutputAsync(
                    [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
                    'test complete',
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
