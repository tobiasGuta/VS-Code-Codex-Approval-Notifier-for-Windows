[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Invoke-Probe {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $Path @Arguments 2>&1 | ForEach-Object { [string]$_ })
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = $output
        }
    }
    catch {
        return [pscustomobject]@{
            ExitCode = -1
            Output   = @($_.Exception.Message)
        }
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }
}

function Test-SchemaNeedle {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Needle
    )

    $match = Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
        Select-String -SimpleMatch $Needle -List -ErrorAction SilentlyContinue |
        Select-Object -First 1

    return [pscustomobject]@{
        Present = ($null -ne $match)
        File    = if ($null -eq $match) { $null } else { $match.Path }
    }
}

Write-Host '# Codex App-Server Experimental Surface Audit'
Write-Host ('Generated: {0:o}' -f [DateTimeOffset]::Now)
Write-Host 'Mode: read-only. No remote-control enable/disable/pairing request is sent.'
Write-Host ''

$processes = @(Get-CimInstance Win32_Process -Filter "Name='codex.exe'" -ErrorAction SilentlyContinue |
    Where-Object { [string]$_.CommandLine -match '(?i)(^|\s)app-server(\s|$)' })

if ($processes.Count -eq 0) {
    Write-Host 'INCONCLUSIVE: no running codex.exe app-server process was found.'
    Write-Host 'Open VS Code with the Codex extension active, then rerun this script.'
    exit 2
}

foreach ($process in $processes) {
    $binary = [string]$process.ExecutablePath
    if ([string]::IsNullOrWhiteSpace($binary) -or -not (Test-Path -LiteralPath $binary)) {
        Write-Host "PID $($process.ProcessId): executable path unavailable; skipping."
        continue
    }

    Write-Host "## Live app-server PID $($process.ProcessId)"
    Write-Host "Executable: $binary"
    Write-Host "Command:    $($process.CommandLine)"
    Write-Host "Startup --remote-control present: $([bool]([string]$process.CommandLine -match '(?i)(^|\s)--remote-control(\s|$)'))"

    $version = Invoke-Probe -Path $binary -Arguments @('--version')
    Write-Host "Version:    $(($version.Output -join ' ').Trim())"
    Write-Host ''

    $schemaHelp = Invoke-Probe -Path $binary -Arguments @('app-server', 'generate-json-schema', '--help')
    $schemaHelpText = $schemaHelp.Output -join "`n"
    $supportsExperimentalSchema = ($schemaHelp.ExitCode -eq 0 -and $schemaHelpText -match '(?m)--experimental\b')

    Write-Host "generate-json-schema help exit: $($schemaHelp.ExitCode)"
    Write-Host "--experimental supported:      $supportsExperimentalSchema"

    $remoteCliHelp = Invoke-Probe -Path $binary -Arguments @('remote-control', '--help')
    Write-Host "top-level remote-control help: exit $($remoteCliHelp.ExitCode)"

    $daemonHelp = Invoke-Probe -Path $binary -Arguments @('app-server', 'daemon', '--help')
    Write-Host "app-server daemon help:        exit $($daemonHelp.ExitCode)"

    if (-not $supportsExperimentalSchema) {
        Write-Host 'INCONCLUSIVE: this binary does not advertise experimental schema generation.'
        Write-Host ''
        continue
    }

    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-app-server-experimental-audit-' + [guid]::NewGuid().ToString('N'))
    $schemaRoot = Join-Path $tempRoot 'schema'

    try {
        New-Item -ItemType Directory -Path $schemaRoot -Force | Out-Null
        $schema = Invoke-Probe -Path $binary -Arguments @(
            'app-server',
            'generate-json-schema',
            '--experimental',
            '--out',
            $schemaRoot
        )

        Write-Host "Experimental schema generation: exit $($schema.ExitCode)"
        if ($schema.ExitCode -ne 0) {
            foreach ($line in $schema.Output) { Write-Host "  $line" }
            Write-Host ''
            continue
        }

        $needles = @(
            'remoteControl/enable',
            'remoteControl/disable',
            'remoteControl/status/read',
            'remoteControl/pairing/start',
            'remoteControl/pairing/status',
            'remoteControl/client/list',
            'remoteControl/client/revoke',
            'remoteControl/status/changed',
            'item/commandExecution/requestApproval',
            'item/fileChange/requestApproval',
            'item/tool/requestUserInput',
            'turn/steer',
            'turn/interrupt',
            'thread/read',
            'thread/loaded/list',
            'serverRequest/resolved'
        )

        $allPresent = $true
        foreach ($needle in $needles) {
            $result = Test-SchemaNeedle -Root $schemaRoot -Needle $needle
            Write-Host ("  {0,-42} {1}" -f $needle, $result.Present)
            if ($needle -like 'remoteControl/*' -and -not $result.Present) {
                $allPresent = $false
            }
        }

        Write-Host ''
        if ($allPresent) {
            Write-Host 'RESULT: the exact live VS Code Codex binary includes the experimental remote-control protocol surface.'
            Write-Host 'NOTE: this proves protocol availability, not yet that an external client can attach to the already-running stdio-owned process.'
        }
        else {
            Write-Host 'RESULT: one or more remote-control methods are absent even from the experimental schema.'
        }
    }
    finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host ''
}
