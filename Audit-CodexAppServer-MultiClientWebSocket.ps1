[CmdletBinding()]
param(
    [string]$TargetCodexPath
)

$ErrorActionPreference = 'Stop'

function Find-LiveVsCodeCodexBinary {
    $paths = @(
        Get-CimInstance Win32_Process -Filter "Name='codex.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                [string]$_.CommandLine -match '(?i)(^|\s)app-server(\s|$)' -and
                -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
                [string]$_.ExecutablePath -match '(?i)\\\.vscode\\extensions\\openai\.chatgpt-[^\\]+\\bin\\windows-x86_64\\codex\.exe$'
            } |
            ForEach-Object { [string]$_.ExecutablePath } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Sort-Object -Unique
    )

    if ($paths.Count -eq 1) {
        return $paths[0]
    }
    if ($paths.Count -gt 1) {
        throw "Multiple live VS Code Codex app-server binaries were found:`r`n$($paths -join "`r`n")`r`nClose extra VS Code instances or pass -TargetCodexPath explicitly."
    }
    throw 'No live VS Code Codex app-server binary was found. Open VS Code with Codex loaded, then rerun this script or pass -TargetCodexPath explicitly.'
}

function Stop-ProbeProcess {
    param([System.Diagnostics.Process]$Process)

    if ($null -eq $Process) { return }
    try {
        if (-not $Process.HasExited) {
            $Process.Kill()
            $Process.WaitForExit(3000) | Out-Null
        }
    }
    catch { }
    finally {
        try { $Process.Dispose() } catch { }
    }
}

function Read-BoundWebSocketUri {
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [int]$TimeoutMilliseconds = 30000
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    $lines = New-Object System.Collections.Generic.List[string]
    $readTask = $Process.StandardError.ReadLineAsync()

    while ([DateTime]::UtcNow -lt $deadline) {
        if ($readTask.Wait(250)) {
            $line = $readTask.Result
            if ($null -eq $line) {
                break
            }
            $lines.Add($line)

            $plain = [regex]::Replace($line, "`e\[[0-?]*[ -/]*[@-~]", '')
            $match = [regex]::Match($plain, 'ws://(?:127\.0\.0\.1|localhost|\[::1\]):\d+')
            if ($match.Success) {
                return [pscustomobject]@{
                    Uri = $match.Value
                    Lines = @($lines)
                }
            }

            $readTask = $Process.StandardError.ReadLineAsync()
            continue
        }

        if ($Process.HasExited) {
            break
        }
    }

    $stderr = $lines -join "`r`n"
    throw "Timed out waiting for the isolated app-server to report its loopback WebSocket address.`r`nStderr captured:`r`n$stderr"
}

function New-ConnectedWebSocket {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [int]$TimeoutMilliseconds = 15000
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    $lastError = $null

    while ([DateTime]::UtcNow -lt $deadline) {
        $socket = New-Object System.Net.WebSockets.ClientWebSocket
        $cts = New-Object System.Threading.CancellationTokenSource
        $cts.CancelAfter(1500)
        try {
            $socket.ConnectAsync([Uri]$Uri, $cts.Token).GetAwaiter().GetResult()
            if ($socket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                return $socket
            }
        }
        catch {
            $lastError = $_.Exception.Message
        }
        finally {
            $cts.Dispose()
        }

        try { $socket.Dispose() } catch { }
        Start-Sleep -Milliseconds 50
    }

    throw "Failed to connect to isolated app-server WebSocket $Uri. Last error: $lastError"
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
        $Socket.SendAsync(
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
                throw 'Isolated app-server WebSocket closed unexpectedly.'
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
    $json = $message | ConvertTo-Json -Compress -Depth 12
    Send-WebSocketText -Socket $Socket -Text $json
}

function Receive-JsonRpcForId {
    param(
        [Parameter(Mandatory)][System.Net.WebSockets.ClientWebSocket]$Socket,
        [Parameter(Mandatory)][int]$Id
    )

    for ($attempt = 0; $attempt -lt 20; $attempt++) {
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

function Initialize-WebSocketClient {
    param(
        [Parameter(Mandatory)][System.Net.WebSockets.ClientWebSocket]$Socket,
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][string]$Name
    )

    $params = [ordered]@{
        clientInfo = [ordered]@{
            name = $Name
            title = 'Codex Approval Notifier WebSocket Audit'
            version = '0.1.0'
        }
        capabilities = [ordered]@{
            experimentalApi = $true
        }
    }

    Send-JsonRpcRequest -Socket $Socket -Id $Id -Method 'initialize' -Params $params
    $response = Receive-JsonRpcForId -Socket $Socket -Id $Id
    if ($null -ne $response.Message.error) {
        throw "Initialize returned an error for $Name: $($response.Raw)"
    }
    if ($null -eq $response.Message.result) {
        throw "Initialize returned no result for $Name: $($response.Raw)"
    }

    Send-WebSocketText -Socket $Socket -Text '{"method":"initialized"}'
    return $response
}

if (-not ('System.Net.WebSockets.ClientWebSocket' -as [type])) {
    throw 'System.Net.WebSockets.ClientWebSocket is unavailable in this PowerShell/.NET runtime.'
}

if ([string]::IsNullOrWhiteSpace($TargetCodexPath)) {
    $TargetCodexPath = Find-LiveVsCodeCodexBinary
}
if (-not (Test-Path -LiteralPath $TargetCodexPath -PathType Leaf)) {
    throw "Codex target not found: $TargetCodexPath"
}
$target = (Resolve-Path -LiteralPath $TargetCodexPath).Path

Write-Host '# Codex App-Server Local Multi-Client WebSocket Audit'
Write-Host ('Generated: {0:o}' -f [DateTimeOffset]::Now)
Write-Host "Target: $target"
Write-Host 'Mode: isolated temporary CODEX_HOME; loopback WebSocket only; no remote-control relay.'
Write-Host ''

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-ws-multiclient-audit-' + [guid]::NewGuid().ToString('N'))
$codexHome = Join-Path $tempRoot 'codex-home'
New-Item -ItemType Directory -Path $codexHome -Force | Out-Null

$process = $null
$ws1 = $null
$ws2 = $null
try {
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $target
    $start.Arguments = '-c features.code_mode_host=true app-server --analytics-default-enabled --listen ws://127.0.0.1:0'
    $start.WorkingDirectory = $codexHome
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['CODEX_HOME'] = $codexHome
    $start.EnvironmentVariables['RUST_LOG'] = 'warn'
    $start.EnvironmentVariables['CODEX_APP_SERVER_MANAGED_CONFIG_PATH'] = (Join-Path $codexHome 'managed_config.toml')

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    if (-not $process.Start()) {
        throw 'Failed to start isolated WebSocket app-server.'
    }

    $bound = Read-BoundWebSocketUri -Process $process
    $uri = $bound.Uri
    if ($uri -notmatch '^ws://(?:127\.0\.0\.1|localhost|\[::1\]):\d+$') {
        throw "App-server did not bind to loopback only: $uri"
    }

    Write-Host "Loopback listener:              $uri"
    Write-Host 'Remote-control relay requested: False'

    $ws1 = New-ConnectedWebSocket -Uri $uri
    $ws2 = New-ConnectedWebSocket -Uri $uri

    $init1 = Initialize-WebSocketClient -Socket $ws1 -Id 1 -Name 'ws_audit_client_one'
    $init2 = Initialize-WebSocketClient -Socket $ws2 -Id 1 -Name 'ws_audit_client_two'

    Write-Host 'Client 1 initialize:            OK'
    Write-Host 'Client 2 initialize:            OK'
    Write-Host 'Same initialize request ID:     True'

    $configParams = [ordered]@{ includeLayers = $false }
    Send-JsonRpcRequest -Socket $ws1 -Id 77 -Method 'config/read' -Params $configParams
    Send-JsonRpcRequest -Socket $ws2 -Id 77 -Method 'config/read' -Params $configParams

    $config1 = Receive-JsonRpcForId -Socket $ws1 -Id 77
    $config2 = Receive-JsonRpcForId -Socket $ws2 -Id 77

    if ($null -ne $config1.Message.error) {
        throw "Client 1 config/read failed: $($config1.Raw)"
    }
    if ($null -ne $config2.Message.error) {
        throw "Client 2 config/read failed: $($config2.Raw)"
    }
    if ($null -eq $config1.Message.result.config -or $null -eq $config2.Message.result.config) {
        throw 'One or both config/read responses did not contain a config result.'
    }

    Write-Host 'Client 1 config/read id 77:     OK'
    Write-Host 'Client 2 config/read id 77:     OK'
    Write-Host 'Per-connection request routing: True'
    Write-Host ''
    Write-Host 'RESULT: the exact VS Code Codex binary supports two independent local WebSocket clients on one app-server process.'
    Write-Host 'This validates a LAN-only companion architecture without using Codex remote-control relay.'
}
finally {
    if ($null -ne $ws1) { try { $ws1.Dispose() } catch { } }
    if ($null -ne $ws2) { try { $ws2.Dispose() } catch { } }
    if ($null -ne $process) {
        try { $process.StandardInput.Close() } catch { }
        Stop-ProbeProcess -Process $process
    }
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
