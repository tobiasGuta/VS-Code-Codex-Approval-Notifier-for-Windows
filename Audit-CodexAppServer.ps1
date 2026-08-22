[CmdletBinding()]
param(
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'

function Write-AuditSection {
    param([Parameter(Mandatory)][string]$Title)
    Write-Host "`n## $Title"
}

function Invoke-CodexProbe {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $Path @Arguments 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
        return [pscustomobject]@{
            ExitCode = $exitCode
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

function Get-ExtensionCandidates {
    $roots = @(
        (Join-Path $env:USERPROFILE '.vscode\extensions'),
        (Join-Path $env:USERPROFILE '.vscode-insiders\extensions')
    )

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }

        foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -Filter 'openai.chatgpt-*' -ErrorAction SilentlyContinue)) {
            $packagePath = Join-Path $dir.FullName 'package.json'
            $version = $null
            if (Test-Path -LiteralPath $packagePath) {
                try {
                    $package = Get-Content -LiteralPath $packagePath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $version = [string]$package.version
                }
                catch {}
            }

            $result.Add([pscustomobject]@{
                Path      = $dir.FullName
                Version   = $version
                Timestamp = $dir.LastWriteTime
            })
        }
    }

    return @($result.ToArray() | Sort-Object Timestamp -Descending)
}

function Get-CodexBinaries {
    param([object[]]$Extensions)

    $paths = New-Object System.Collections.Generic.List[string]

    foreach ($extension in @($Extensions)) {
        foreach ($file in @(Get-ChildItem -LiteralPath $extension.Path -Recurse -File -Filter 'codex.exe' -ErrorAction SilentlyContinue)) {
            $paths.Add($file.FullName)
        }
    }

    try {
        $pathCommand = Get-Command codex.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $pathCommand -and -not [string]::IsNullOrWhiteSpace([string]$pathCommand.Source)) {
            $paths.Add([string]$pathCommand.Source)
        }
    }
    catch {}

    try {
        foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='codex.exe'" -ErrorAction SilentlyContinue)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$process.ExecutablePath)) {
                $paths.Add([string]$process.ExecutablePath)
            }
        }
    }
    catch {}

    return @($paths.ToArray() | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
}

function Get-RunningCodexProcesses {
    $result = New-Object System.Collections.Generic.List[object]

    try {
        $processes = @(Get-CimInstance Win32_Process -Filter "Name='codex.exe'" -ErrorAction SilentlyContinue)
    }
    catch {
        $processes = @()
    }

    foreach ($process in $processes) {
        $parentName = $null
        $parentPath = $null
        try {
            $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($process.ParentProcessId)" -ErrorAction SilentlyContinue
            if ($null -ne $parent) {
                $parentName = [string]$parent.Name
                $parentPath = [string]$parent.ExecutablePath
            }
        }
        catch {}

        $listeners = @()
        if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
            try {
                $listeners = @(Get-NetTCPConnection -OwningProcess $process.ProcessId -State Listen -ErrorAction SilentlyContinue |
                    ForEach-Object { "$($_.LocalAddress):$($_.LocalPort)" })
            }
            catch {}
        }

        $result.Add([pscustomobject]@{
            ProcessId       = [int]$process.ProcessId
            ParentProcessId = [int]$process.ParentProcessId
            ParentName      = $parentName
            ParentPath      = $parentPath
            ExecutablePath  = [string]$process.ExecutablePath
            CommandLine     = [string]$process.CommandLine
            TcpListeners    = @($listeners)
            IsAppServer     = ([string]$process.CommandLine -match '(?i)(^|\s)app-server(\s|$)')
        })
    }

    return $result.ToArray()
}

function Get-VSCodeCliExecutableSetting {
    $paths = @(
        (Join-Path $env:APPDATA 'Code\User\settings.json'),
        (Join-Path $env:APPDATA 'Code - Insiders\User\settings.json')
    )

    $matches = New-Object System.Collections.Generic.List[object]
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try {
            $lineMatches = @(Select-String -LiteralPath $path -SimpleMatch 'chatgpt.cliExecutable' -ErrorAction SilentlyContinue)
            foreach ($lineMatch in $lineMatches) {
                $matches.Add([pscustomobject]@{
                    SettingsPath = $path
                    LineNumber   = $lineMatch.LineNumber
                    Line         = $lineMatch.Line.Trim()
                })
            }
        }
        catch {}
    }
    return $matches.ToArray()
}

function Test-SchemaCapability {
    param(
        [Parameter(Mandatory)][string]$SchemaRoot,
        [Parameter(Mandatory)][string]$Needle
    )

    try {
        $match = Get-ChildItem -LiteralPath $SchemaRoot -Recurse -File -ErrorAction SilentlyContinue |
            Select-String -SimpleMatch $Needle -List -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -eq $match) {
            return [pscustomobject]@{ Present = $false; File = $null }
        }
        return [pscustomobject]@{ Present = $true; File = $match.Path }
    }
    catch {
        return [pscustomobject]@{ Present = $false; File = $null }
    }
}

function Get-BinaryAudit {
    param([Parameter(Mandatory)][string]$Path)

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    $versionProbe = Invoke-CodexProbe -Path $Path -Arguments @('--version')
    $helpProbe = Invoke-CodexProbe -Path $Path -Arguments @('app-server', '--help')

    # This is intentionally combined with --help. Clap validates whether the hidden
    # flag exists, then exits after printing help; app-server is never started and
    # remote control is never enabled by this probe.
    $remoteFlagProbe = Invoke-CodexProbe -Path $Path -Arguments @('app-server', '--remote-control', '--help')

    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-app-server-audit-' + [guid]::NewGuid().ToString('N'))
    $schemaRoot = Join-Path $tempRoot 'schema'
    $schemaProbe = $null
    $capabilities = [ordered]@{}

    try {
        New-Item -ItemType Directory -Path $schemaRoot -Force | Out-Null
        $schemaProbe = Invoke-CodexProbe -Path $Path -Arguments @('app-server', 'generate-json-schema', '--out', $schemaRoot)

        if ($schemaProbe.ExitCode -eq 0) {
            $needles = @(
                'remoteControl/enable',
                'remoteControl/disable',
                'remoteControl/status/read',
                'remoteControl/pairing/start',
                'remoteControl/pairing/status',
                'remoteControl/client/list',
                'remoteControl/client/revoke',
                'item/commandExecution/requestApproval',
                'item/fileChange/requestApproval',
                'item/tool/requestUserInput',
                'turn/steer',
                'turn/interrupt',
                'thread/read',
                'thread/loaded/list',
                'serverRequest/resolved'
            )

            foreach ($needle in $needles) {
                $capabilities[$needle] = Test-SchemaCapability -SchemaRoot $schemaRoot -Needle $needle
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    $helpText = ($helpProbe.Output -join "`n")

    return [pscustomobject]@{
        Path                  = $Path
        FileVersion           = [string]$item.VersionInfo.FileVersion
        ProductVersion        = [string]$item.VersionInfo.ProductVersion
        CodexVersion          = ($versionProbe.Output -join ' ').Trim()
        VersionExitCode       = $versionProbe.ExitCode
        AppServerHelpExitCode = $helpProbe.ExitCode
        SupportsListen        = ($helpText -match '(?m)--listen')
        MentionsStdio         = ($helpText -match '(?i)stdio')
        MentionsWebSocket     = ($helpText -match '(?i)ws://|websocket')
        RemoteFlagAccepted    = ($remoteFlagProbe.ExitCode -eq 0)
        SchemaExitCode        = if ($null -eq $schemaProbe) { -1 } else { $schemaProbe.ExitCode }
        SchemaCapabilities    = [pscustomobject]$capabilities
        VersionOutput         = @($versionProbe.Output)
        HelpOutput            = @($helpProbe.Output)
        RemoteFlagProbeOutput = @($remoteFlagProbe.Output)
        SchemaOutput          = if ($null -eq $schemaProbe) { @() } else { @($schemaProbe.Output) }
    }
}

Write-Host '# Codex App-Server Feasibility Audit'
Write-Host ('Generated: {0:o}' -f [DateTimeOffset]::Now)
Write-Host 'Mode: read-only inspection; no Codex/VS Code configuration is changed.'

Write-AuditSection 'VS Code Codex extensions'
$extensions = @(Get-ExtensionCandidates)
if ($extensions.Count -eq 0) {
    Write-Host 'No openai.chatgpt-* extension directories were found in the standard VS Code locations.'
}
else {
    foreach ($extension in $extensions) {
        Write-Host ("Version={0}  Path={1}" -f $extension.Version, $extension.Path)
    }
}

Write-AuditSection 'Running Codex processes'
$running = @(Get-RunningCodexProcesses)
if ($running.Count -eq 0) {
    Write-Host 'No running codex.exe processes were found.'
}
else {
    foreach ($process in $running) {
        Write-Host "PID $($process.ProcessId)  Parent=$($process.ParentName)($($process.ParentProcessId))  AppServer=$($process.IsAppServer)"
        Write-Host "Executable: $($process.ExecutablePath)"
        Write-Host "Command:    $($process.CommandLine)"
        if ($process.TcpListeners.Count -gt 0) {
            Write-Host "Listeners:  $($process.TcpListeners -join ', ')"
        }
        else {
            Write-Host 'Listeners:  none detected'
        }
        Write-Host ''
    }
}

Write-AuditSection 'VS Code Codex CLI override'
$cliOverrides = @(Get-VSCodeCliExecutableSetting)
if ($cliOverrides.Count -eq 0) {
    Write-Host 'No chatgpt.cliExecutable setting was found in standard VS Code user settings files.'
}
else {
    foreach ($override in $cliOverrides) {
        Write-Host "$($override.SettingsPath):$($override.LineNumber)  $($override.Line)"
    }
}

Write-AuditSection 'Codex binary capabilities'
$binaries = @(Get-CodexBinaries -Extensions $extensions)
$binaryAudits = New-Object System.Collections.Generic.List[object]
if ($binaries.Count -eq 0) {
    Write-Host 'No codex.exe binaries were found.'
}
else {
    foreach ($binary in $binaries) {
        Write-Host "`n### $binary"
        $audit = Get-BinaryAudit -Path $binary
        $binaryAudits.Add($audit)

        Write-Host "Codex version:            $($audit.CodexVersion)"
        Write-Host "File version:             $($audit.FileVersion)"
        Write-Host "App-server help:          exit $($audit.AppServerHelpExitCode)"
        Write-Host "--listen present:         $($audit.SupportsListen)"
        Write-Host "stdio mentioned:          $($audit.MentionsStdio)"
        Write-Host "WebSocket mentioned:      $($audit.MentionsWebSocket)"
        Write-Host "--remote-control accepted:$($audit.RemoteFlagAccepted)"
        Write-Host "Schema generation:        exit $($audit.SchemaExitCode)"

        foreach ($property in $audit.SchemaCapabilities.PSObject.Properties) {
            Write-Host ("  {0,-42} {1}" -f $property.Name, $property.Value.Present)
        }
    }
}

$activeAppServers = @($running | Where-Object { $_.IsAppServer })
$sameBinaryMatches = New-Object System.Collections.Generic.List[object]
foreach ($process in $activeAppServers) {
    $matchedAudit = @($binaryAudits.ToArray() | Where-Object { $_.Path -eq $process.ExecutablePath } | Select-Object -First 1)
    if ($matchedAudit.Count -gt 0) {
        $sameBinaryMatches.Add([pscustomobject]@{
            Process = $process
            Audit   = $matchedAudit[0]
        })
    }
}

Write-AuditSection 'Preliminary local conclusion'
if ($activeAppServers.Count -eq 0) {
    Write-Host 'INCONCLUSIVE: no live VS Code-owned app-server process was observed. Open VS Code with Codex active and rerun this audit.'
}
else {
    foreach ($match in $sameBinaryMatches.ToArray()) {
        Write-Host "Live app-server PID $($match.Process.ProcessId) uses audited binary: $($match.Audit.Path)"
        Write-Host "Remote-control flag accepted by same binary: $($match.Audit.RemoteFlagAccepted)"
        $remoteEnable = $match.Audit.SchemaCapabilities.PSObject.Properties['remoteControl/enable']
        Write-Host "remoteControl/enable in same binary schema: $($remoteEnable.Value.Present)"
    }

    if ($sameBinaryMatches.Count -eq 0) {
        Write-Host 'A live app-server exists, but its executable path was not among the successfully audited binaries.'
    }

    $hasTcpListener = @($activeAppServers | Where-Object { $_.TcpListeners.Count -gt 0 }).Count -gt 0
    if ($hasTcpListener) {
        Write-Host 'A live app-server TCP listener was detected. Its command line/listener must be reviewed before any connection attempt.'
    }
    else {
        Write-Host 'No live app-server TCP listener was detected. This is consistent with VS Code owning a stdio app-server, but the command line is authoritative.'
    }
}

$result = [pscustomobject]@{
    GeneratedAt        = [DateTimeOffset]::Now.ToString('o')
    Extensions         = $extensions
    RunningProcesses   = $running
    CliExecutable      = $cliOverrides
    BinaryAudits       = $binaryAudits.ToArray()
    ActiveAppServerPids = @($activeAppServers | ForEach-Object { $_.ProcessId })
}

if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
    $resolvedOutFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
    $parent = Split-Path -Parent $resolvedOutFile
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resolvedOutFile -Encoding UTF8
    Write-Host "`nJSON report written to: $resolvedOutFile"
}
