[CmdletBinding()]
param(
    [string]$InstallDir = $PSScriptRoot,
    [string]$LogPath = (Join-Path $env:TEMP 'CodexRemoteApprovals-unconfigure.log')
)

$ErrorActionPreference = 'Stop'

function Write-SetupLog([string]$Message) {
    $line = ('[{0}] {1}' -f ([DateTimeOffset]::Now.ToString('o')), $Message)
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Decode-JsonPath([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $slash = [string][char]92
    return $Value.Replace($slash + $slash, $slash)
}

function Encode-JsonPath([string]$Value) {
    $slash = [string][char]92
    return $Value.Replace($slash, $slash + $slash).Replace('"', $slash + '"')
}

function Get-CliExecutableMatch([string]$Text) {
    return [regex]::Match($Text, '(?m)^\s*["'']chatgpt\.cliExecutable["'']\s*:\s*["''](?<v>[^"'']+)["'']\s*,?\s*(?://.*)?$')
}

function Normalize-PathValue([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $decoded = Decode-JsonPath $Value
    try { return [IO.Path]::GetFullPath($decoded) } catch { return $decoded }
}

try {
    Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
    Write-SetupLog 'Starting Codex Remote Approvals installed-payload rollback.'

    if (@(Get-Process -Name Code -ErrorAction SilentlyContinue).Count -gt 0) {
        throw 'Close all VS Code windows before uninstalling Codex Remote Approvals.'
    }

    $InstallDir = [IO.Path]::GetFullPath($InstallDir)
    $statePath = Join-Path $InstallDir 'install-state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        Write-SetupLog 'No installer ownership state exists; nothing to restore.'
        exit 0
    }

    $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $settingsPath = [string]$state.settingsPath
    $installedShim = Normalize-PathValue ([string]$state.installedShim)
    $previous = [string]$state.previousCliExecutable

    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
            ([string]$_.ExecutablePath).StartsWith($InstallDir, [StringComparison]::OrdinalIgnoreCase)
        } |
        ForEach-Object {
            if ($_.ProcessId -ne $PID) {
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            }
        }
    Start-Sleep -Milliseconds 250

    if (-not [string]::IsNullOrWhiteSpace($settingsPath) -and (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        $text = [IO.File]::ReadAllText($settingsPath)
        $match = Get-CliExecutableMatch $text
        if ($match.Success) {
            $current = Normalize-PathValue $match.Groups['v'].Value
            if ([string]::Equals($current, $installedShim, [StringComparison]::OrdinalIgnoreCase)) {
                if (-not [string]::IsNullOrWhiteSpace($previous)) {
                    $jsonPrevious = Encode-JsonPath $previous
                    $replacement = '    "chatgpt.cliExecutable": "' + $jsonPrevious + '",'
                    $text = $text.Remove($match.Index, $match.Length).Insert($match.Index, $replacement)
                }
                else {
                    $start = $match.Index
                    $prefix = $text.Substring(0, $start)
                    $commentPattern = '(?m)^\s*// Codex Remote Approvals\s*\r?\n\s*$'
                    $comments = [regex]::Matches($prefix, $commentPattern)
                    if ($comments.Count -gt 0) {
                        $last = $comments[$comments.Count - 1]
                        if ($last.Index + $last.Length -eq $prefix.Length) { $start = $last.Index }
                    }
                    $text = $text.Remove($start, ($match.Index + $match.Length) - $start)
                }

                [IO.File]::WriteAllText($settingsPath, $text, (New-Object Text.UTF8Encoding($false)))
                Write-SetupLog 'VS Code Codex CLI setting restored.'
            }
            else {
                Write-SetupLog 'chatgpt.cliExecutable changed after installation; leaving user-controlled value untouched.'
            }
        }
    }

    Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
    Write-SetupLog 'Rollback completed successfully.'
    exit 0
}
catch {
    try { Write-SetupLog ('FAILED: ' + $_.Exception.Message) } catch { }
    Write-Error $_.Exception.Message
    exit 1
}
