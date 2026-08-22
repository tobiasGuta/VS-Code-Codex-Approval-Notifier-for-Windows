[CmdletBinding()]
param(
    [string]$ShimDirectory = (Join-Path $PSScriptRoot 'shim-build')
)

$ErrorActionPreference = 'Stop'

$shim = Join-Path $ShimDirectory 'CodexAppServerShim.exe'
$targetFile = Join-Path $ShimDirectory 'CodexAppServerShim.target'
if (-not (Test-Path -LiteralPath $shim -PathType Leaf)) {
    throw "Shim executable not found: $shim"
}
if (-not (Test-Path -LiteralPath $targetFile -PathType Leaf)) {
    throw "Shim target file not found: $targetFile"
}

$target = (Get-Content -LiteralPath $targetFile -Raw -Encoding UTF8).Trim()
if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
    throw "Configured Codex target not found: $target"
}

function Invoke-Capture {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $output = @(& $Path @Arguments 2>&1 | ForEach-Object { [string]$_ })
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = $output
        Text     = ($output -join "`n")
    }
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

function Find-ShimChildProcess {
    param(
        [Parameter(Mandatory)][int]$ShimProcessId,
        [int]$TimeoutMilliseconds = 5000
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    do {
        $child = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                [int]$_.ParentProcessId -eq $ShimProcessId -and
                [string]$_.Name -ieq 'codex.exe'
            } |
            Select-Object -First 1
        if ($null -ne $child) {
            return $child
        }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)

    return $null
}

function Invoke-InitializeProbe {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$CodexHome,
        [Parameter(Mandatory)][bool]$DisableShimRemoteControl,
        [bool]$ExpectRemoteControlChild = $false
    )

    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $Path
    $start.Arguments = '-c features.code_mode_host=true app-server --analytics-default-enabled'
    $start.WorkingDirectory = $CodexHome
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['CODEX_HOME'] = $CodexHome
    $start.EnvironmentVariables['RUST_LOG'] = 'warn'
    $start.EnvironmentVariables['CODEX_APP_SERVER_MANAGED_CONFIG_PATH'] = (Join-Path $CodexHome 'managed_config.toml')
    if ($DisableShimRemoteControl) {
        $start.EnvironmentVariables['CODEX_APPROVAL_NOTIFIER_SHIM_DISABLE_REMOTE_CONTROL_FOR_TESTS'] = '1'
    }
    else {
        $start.EnvironmentVariables.Remove('CODEX_APPROVAL_NOTIFIER_SHIM_DISABLE_REMOTE_CONTROL_FOR_TESTS')
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    $stderrTask = $null
    $remoteControlChildVerified = $false
    $remoteControlChildCommandLine = $null
    try {
        if (-not $process.Start()) {
            throw "Failed to start protocol probe: $Path"
        }

        if ($ExpectRemoteControlChild) {
            $child = Find-ShimChildProcess -ShimProcessId $process.Id
            if ($null -eq $child) {
                throw "Shim child codex.exe was not found for PID $($process.Id)."
            }
            $remoteControlChildCommandLine = [string]$child.CommandLine
            if ($remoteControlChildCommandLine -notmatch '(?i)(^|\s)--remote-control(\s|$)') {
                throw "Shim child command line did not include --remote-control:`r`n$remoteControlChildCommandLine"
            }
            $remoteControlChildVerified = $true
        }

        # Drain stderr asynchronously so a full stderr pipe can never block the app-server.
        $stderrTask = $process.StandardError.ReadToEndAsync()

        $request = [ordered]@{
            id = 1
            method = 'initialize'
            params = [ordered]@{
                clientInfo = [ordered]@{
                    name = 'codex-approval-notifier-shim-test'
                    title = 'Codex Approval Notifier Shim Test'
                    version = '0.1.0'
                }
                capabilities = [ordered]@{
                    experimentalApi = $true
                }
            }
        } | ConvertTo-Json -Compress -Depth 8

        $process.StandardInput.WriteLine($request)
        $process.StandardInput.Flush()

        $readTask = $process.StandardOutput.ReadLineAsync()
        if (-not $readTask.Wait(15000)) {
            $stderr = if ($null -ne $stderrTask -and $stderrTask.IsCompleted) { $stderrTask.Result } else { '' }
            throw "Timed out waiting for initialize response from $Path.`r`nStderr:`r`n$stderr"
        }

        $line = $readTask.Result
        if ([string]::IsNullOrWhiteSpace($line)) {
            throw "Protocol probe returned an empty initialize response: $Path"
        }

        try {
            $response = $line | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw "Protocol probe returned non-JSON stdout from $Path`r`n$line"
        }

        if ([string]$response.id -ne '1') {
            throw "Initialize response id mismatch from $Path. Response: $line"
        }
        if ($null -ne $response.error) {
            throw "Initialize returned JSON-RPC error from $Path. Response: $line"
        }
        if ($null -eq $response.result) {
            throw "Initialize response has no result from $Path. Response: $line"
        }

        # Ack initialization exactly as Codex's own app-server test client does.
        $initialized = '{"method":"initialized"}'
        $process.StandardInput.WriteLine($initialized)
        $process.StandardInput.Flush()

        return [pscustomobject]@{
            Raw = $line
            Response = $response
            UserAgent = [string]$response.result.userAgent
            CodexHome = [string]$response.result.codexHome
            PlatformFamily = [string]$response.result.platformFamily
            PlatformOs = [string]$response.result.platformOs
            RemoteControlChildVerified = $remoteControlChildVerified
            RemoteControlChildCommandLine = $remoteControlChildCommandLine
        }
    }
    finally {
        try { $process.StandardInput.Close() } catch { }
        Stop-ProbeProcess -Process $process
    }
}

Write-Host '# Codex App-Server Shim Acceptance'
Write-Host "Shim:   $shim"
Write-Host "Target: $target"
Write-Host ''

$targetVersion = Invoke-Capture -Path $target -Arguments @('--version')
$shimVersion = Invoke-Capture -Path $shim -Arguments @('--version')

Write-Host "Target version exit: $($targetVersion.ExitCode)"
Write-Host "Shim version exit:   $($shimVersion.ExitCode)"
Write-Host "Version output equal: $($targetVersion.Text -eq $shimVersion.Text)"

if ($targetVersion.ExitCode -ne $shimVersion.ExitCode -or $targetVersion.Text -ne $shimVersion.Text) {
    throw 'Version passthrough failed.'
}

$targetHelp = Invoke-Capture -Path $target -Arguments @('app-server', '--help')
$shimHelp = Invoke-Capture -Path $shim -Arguments @('app-server', '--help')

Write-Host "App-server help exit equal: $($targetHelp.ExitCode -eq $shimHelp.ExitCode)"
Write-Host "App-server help output equal: $($targetHelp.Text -eq $shimHelp.Text)"

if ($targetHelp.ExitCode -ne $shimHelp.ExitCode -or $targetHelp.Text -ne $shimHelp.Text) {
    throw 'App-server help passthrough failed.'
}

$targetSchemaHelp = Invoke-Capture -Path $target -Arguments @('app-server', 'generate-json-schema', '--help')
$shimSchemaHelp = Invoke-Capture -Path $shim -Arguments @('app-server', 'generate-json-schema', '--help')

Write-Host "Schema tooling passthrough equal: $($targetSchemaHelp.ExitCode -eq $shimSchemaHelp.ExitCode -and $targetSchemaHelp.Text -eq $shimSchemaHelp.Text)"

if ($targetSchemaHelp.ExitCode -ne $shimSchemaHelp.ExitCode -or $targetSchemaHelp.Text -ne $shimSchemaHelp.Text) {
    throw 'App-server tooling passthrough failed.'
}

Write-Host ''
Write-Host '## Real stdio app-server protocol round-trip'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-shim-protocol-' + [guid]::NewGuid().ToString('N'))
$targetHome = Join-Path $tempRoot 'target-home'
$shimHome = Join-Path $tempRoot 'shim-home'
$shimRemoteHome = Join-Path $tempRoot 'shim-remote-home'
New-Item -ItemType Directory -Path $targetHome -Force | Out-Null
New-Item -ItemType Directory -Path $shimHome -Force | Out-Null
New-Item -ItemType Directory -Path $shimRemoteHome -Force | Out-Null

try {
    $directProbe = Invoke-InitializeProbe -Path $target -CodexHome $targetHome -DisableShimRemoteControl:$false
    $shimProbe = Invoke-InitializeProbe -Path $shim -CodexHome $shimHome -DisableShimRemoteControl:$true
    $shimRemoteProbe = Invoke-InitializeProbe -Path $shim -CodexHome $shimRemoteHome -DisableShimRemoteControl:$false -ExpectRemoteControlChild:$true

    $userAgentEqual = $directProbe.UserAgent -eq $shimProbe.UserAgent
    $platformFamilyEqual = $directProbe.PlatformFamily -eq $shimProbe.PlatformFamily
    $platformOsEqual = $directProbe.PlatformOs -eq $shimProbe.PlatformOs
    $directHomeCorrect = [IO.Path]::GetFullPath($directProbe.CodexHome) -eq [IO.Path]::GetFullPath($targetHome)
    $shimHomeCorrect = [IO.Path]::GetFullPath($shimProbe.CodexHome) -eq [IO.Path]::GetFullPath($shimHome)
    $remoteHomeCorrect = [IO.Path]::GetFullPath($shimRemoteProbe.CodexHome) -eq [IO.Path]::GetFullPath($shimRemoteHome)
    $remoteMetadataEqual =
        $directProbe.UserAgent -eq $shimRemoteProbe.UserAgent -and
        $directProbe.PlatformFamily -eq $shimRemoteProbe.PlatformFamily -and
        $directProbe.PlatformOs -eq $shimRemoteProbe.PlatformOs

    Write-Host "Direct initialize response:          OK"
    Write-Host "Shim initialize response:            OK"
    Write-Host "User-agent equal:                    $userAgentEqual"
    Write-Host "Platform family equal:               $platformFamilyEqual"
    Write-Host "Platform OS equal:                   $platformOsEqual"
    Write-Host "Direct CODEX_HOME preserved:         $directHomeCorrect"
    Write-Host "Shim CODEX_HOME preserved:           $shimHomeCorrect"
    Write-Host ''
    Write-Host '## Remote-control-enabled app-server round-trip'
    Write-Host "Shim child --remote-control verified: $($shimRemoteProbe.RemoteControlChildVerified)"
    Write-Host "Remote initialize response:           OK"
    Write-Host "Remote metadata equal:                $remoteMetadataEqual"
    Write-Host "Remote CODEX_HOME preserved:          $remoteHomeCorrect"

    if (-not ($userAgentEqual -and $platformFamilyEqual -and $platformOsEqual -and $directHomeCorrect -and $shimHomeCorrect)) {
        throw 'Real app-server protocol passthrough comparison failed.'
    }
    if (-not ($shimRemoteProbe.RemoteControlChildVerified -and $remoteMetadataEqual -and $remoteHomeCorrect)) {
        throw 'Remote-control-enabled app-server protocol acceptance failed.'
    }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host 'PASS: CLI/tooling passthrough, raw stdio JSON-RPC, and --remote-control startup all passed in isolation.'
Write-Host 'The protocol probes used temporary CODEX_HOME directories and did not change VS Code settings.'
