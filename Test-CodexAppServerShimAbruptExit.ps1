[CmdletBinding()]
param(
    [string]$ShimDirectory = (Join-Path $PSScriptRoot 'shim-build'),
    [int]$TimeoutMilliseconds = 8000
)

$ErrorActionPreference = 'Stop'

function Wait-Until {
    param(
        [Parameter(Mandatory)][scriptblock]$Condition,
        [Parameter(Mandatory)][string]$Description,
        [int]$Timeout = 8000
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($Timeout)
    do {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "Timed out waiting for $Description."
}

$sourceShim = Join-Path $ShimDirectory 'CodexAppServerShim.exe'
$sourceTarget = Join-Path $ShimDirectory 'CodexAppServerShim.target'
if (-not (Test-Path -LiteralPath $sourceShim -PathType Leaf)) {
    throw "Shim executable not found: $sourceShim"
}
if (-not (Test-Path -LiteralPath $sourceTarget -PathType Leaf)) {
    throw "Shim target file not found: $sourceTarget"
}

$target = (Get-Content -LiteralPath $sourceTarget -Raw -Encoding UTF8).Trim().Trim('"')
if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
    throw "Configured Codex target not found: $target"
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-shim-abrupt-' + [guid]::NewGuid().ToString('N'))
$tempShimDir = Join-Path $tempRoot 'shim'
$codexHome = Join-Path $tempRoot 'codex-home'
New-Item -ItemType Directory -Path $tempShimDir -Force | Out-Null
New-Item -ItemType Directory -Path $codexHome -Force | Out-Null

$shim = Join-Path $tempShimDir 'CodexAppServerShim.exe'
$targetFile = Join-Path $tempShimDir 'CodexAppServerShim.target'
$modeFile = Join-Path $tempShimDir 'CodexAppServerShim.mode'
Copy-Item -LiteralPath $sourceShim -Destination $shim -Force
Set-Content -LiteralPath $targetFile -Value $target -Encoding UTF8
Set-Content -LiteralPath $modeFile -Value 'local-bridge' -Encoding ASCII

$process = $null
$stderrTask = $null
$childPid = $null
$descriptorPath = $null
$tokenPath = $null
$cleanupChildRequired = $false

try {
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $shim
    $start.Arguments = '-c features.code_mode_host=true app-server --analytics-default-enabled'
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
        throw 'Failed to start local-bridge shim probe.'
    }
    $stderrTask = $process.StandardError.ReadToEndAsync()

    $descriptorPath = Join-Path $env:LOCALAPPDATA "CodexApprovalNotifier\local-bridge\bridge-$($process.Id).json"
    $tokenPath = Join-Path $env:LOCALAPPDATA "CodexApprovalNotifier\local-bridge\bridge-$($process.Id).token"

    Wait-Until -Timeout $TimeoutMilliseconds -Description 'local bridge descriptor' -Condition {
        Test-Path -LiteralPath $descriptorPath -PathType Leaf
    }

    $descriptor = Get-Content -LiteralPath $descriptorPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $childPid = [int]$descriptor.codexPid
    if ($childPid -le 0) { throw 'Bridge descriptor did not contain a valid Codex child PID.' }
    if ([int]$descriptor.shimPid -ne $process.Id) { throw 'Bridge descriptor shim PID mismatch.' }
    if ([string]$descriptor.tokenFile -ne $tokenPath) { throw 'Bridge descriptor token path mismatch.' }

    if (-not (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) {
        throw "Codex child PID $childPid was not alive before abrupt-exit test."
    }
    if (-not (Test-Path -LiteralPath $tokenPath -PathType Leaf)) {
        throw 'Bridge token was not present before abrupt-exit test.'
    }

    Write-Host '# Abrupt shim lifecycle acceptance'
    Write-Host "Shim PID:       $($process.Id)"
    Write-Host "Codex child PID: $childPid"
    Write-Host "Descriptor:     $descriptorPath"
    Write-Host "Token:          $tokenPath"
    Write-Host ''
    Write-Host 'Hard-killing shim without closing stdin or WebSocket...'

    $process.Kill()
    $process.WaitForExit(5000) | Out-Null

    Wait-Until -Timeout $TimeoutMilliseconds -Description 'Codex child termination after shim death' -Condition {
        $null -eq (Get-Process -Id $childPid -ErrorAction SilentlyContinue)
    }

    Wait-Until -Timeout $TimeoutMilliseconds -Description 'bridge descriptor delete-on-close cleanup' -Condition {
        -not (Test-Path -LiteralPath $descriptorPath)
    }

    Wait-Until -Timeout $TimeoutMilliseconds -Description 'bridge token delete-on-close cleanup' -Condition {
        -not (Test-Path -LiteralPath $tokenPath)
    }

    Write-Host 'Codex child terminated: PASS'
    Write-Host 'Descriptor removed:      PASS'
    Write-Host 'Token removed:           PASS'
    Write-Host ''
    Write-Host 'PASS: abrupt shim death cannot orphan its Codex app-server or bridge credentials.' -ForegroundColor Green
}
finally {
    if ($null -ne $process) {
        try {
            if (-not $process.HasExited) {
                $process.Kill()
                $process.WaitForExit(3000) | Out-Null
            }
        }
        catch { }
        try { $process.Dispose() } catch { }
    }

    if ($null -ne $childPid) {
        $remaining = Get-Process -Id $childPid -ErrorAction SilentlyContinue
        if ($null -ne $remaining) {
            $cleanupChildRequired = $true
            Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($descriptorPath)) {
        Remove-Item -LiteralPath $descriptorPath -Force -ErrorAction SilentlyContinue
    }
    if (-not [string]::IsNullOrWhiteSpace($tokenPath)) {
        Remove-Item -LiteralPath $tokenPath -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue

    if ($cleanupChildRequired) {
        throw 'FAIL: test cleanup had to terminate a surviving Codex child process.'
    }
}
