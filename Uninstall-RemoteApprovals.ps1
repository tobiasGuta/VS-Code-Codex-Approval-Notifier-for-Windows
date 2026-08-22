[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-CliExecutableMatch([string]$Text) {
    return [regex]::Match($Text, '(?m)^\s*["'']chatgpt\.cliExecutable["'']\s*:\s*["''](?<v>[^"'']+)["'']\s*,?\s*(?://.*)?$')
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

function Normalize-SettingPath([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $decoded = Decode-JsonPath $Value
    try { return [IO.Path]::GetFullPath($decoded) } catch { return $decoded }
}

if (@(Get-Process -Name Code -ErrorAction SilentlyContinue).Count -gt 0) {
    throw 'Close all VS Code windows before uninstalling Remote Approvals. The uninstaller will not terminate VS Code for you.'
}

$installDir = Join-Path $env:LOCALAPPDATA 'CodexApprovalNotifier\remote'
$statePath = Join-Path $installDir 'install-state.json'
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    Write-Host 'Codex Remote Approvals is not installed.'
    exit 0
}

$state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
$settingsPath = [string]$state.settingsPath
$installedShim = Normalize-SettingPath ([string]$state.installedShim)
$previous = [string]$state.previousCliExecutable
$startupShortcut = [string]$state.startupShortcut
$programShortcut = [string]$state.programShortcut

$ownedProcesses = @(
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
        ([string]$_.ExecutablePath).StartsWith($installDir, [StringComparison]::OrdinalIgnoreCase)
    }
)
foreach ($process in $ownedProcesses) {
    Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Milliseconds 350

if (-not [string]::IsNullOrWhiteSpace($settingsPath) -and (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    $text = [IO.File]::ReadAllText($settingsPath)
    $match = Get-CliExecutableMatch $text
    if ($match.Success) {
        $current = Normalize-SettingPath $match.Groups['v'].Value
        if ([string]::Equals($current, $installedShim, [StringComparison]::OrdinalIgnoreCase)) {
            if (-not [string]::IsNullOrWhiteSpace($previous)) {
                $jsonPrevious = Encode-JsonPath $previous
                $replacement = '    "chatgpt.cliExecutable": "' + $jsonPrevious + '",'
                $text = $text.Remove($match.Index, $match.Length).Insert($match.Index, $replacement)
            }
            else {
                $start = $match.Index
                $prefix = $text.Substring(0, $start)
                $commentPattern = '(?m)^\s*// Codex Approval Notifier Remote Approvals\s*\r?\n\s*$'
                $comments = [regex]::Matches($prefix, $commentPattern)
                if ($comments.Count -gt 0) {
                    $last = $comments[$comments.Count - 1]
                    if ($last.Index + $last.Length -eq $prefix.Length) { $start = $last.Index }
                }
                $text = $text.Remove($start, ($match.Index + $match.Length) - $start)
            }
            [IO.File]::WriteAllText($settingsPath, $text, (New-Object Text.UTF8Encoding($false)))
            Write-Host 'VS Code Codex CLI setting restored.'
        }
        else {
            Write-Warning 'chatgpt.cliExecutable no longer points to the installed Remote Approvals shim. Leaving the user-controlled setting unchanged.'
        }
    }
}

foreach ($shortcut in @($startupShortcut, $programShortcut)) {
    if (-not [string]::IsNullOrWhiteSpace($shortcut)) {
        Remove-Item -LiteralPath $shortcut -Force -ErrorAction SilentlyContinue
    }
}

# Shared development runtime directories are intentionally left alone. Installed
# companion/gateway instances remove their own descriptor/token files on normal
# shutdown, and the uninstaller must not delete state belonging to a manual/dev run.
Remove-Item -LiteralPath $installDir -Recurse -Force

Write-Host ''
Write-Host 'Codex Remote Approvals uninstalled.' -ForegroundColor Green
Write-Host 'VS Code can now be reopened with the restored Codex CLI setting.' -ForegroundColor Cyan
