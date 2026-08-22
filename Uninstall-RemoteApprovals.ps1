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

Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
        ([string]$_.ExecutablePath).StartsWith($installDir, [StringComparison]::OrdinalIgnoreCase)
    } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 250

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

if (-not [string]::IsNullOrWhiteSpace($startupShortcut)) {
    Remove-Item -LiteralPath $startupShortcut -Force -ErrorAction SilentlyContinue
}

foreach ($sub in @('companion','lan-gateway')) {
    $runtime = Join-Path $env:LOCALAPPDATA "CodexApprovalNotifier\$sub"
    if (Test-Path -LiteralPath $runtime) { Remove-Item -LiteralPath $runtime -Recurse -Force -ErrorAction SilentlyContinue }
}

Remove-Item -LiteralPath $installDir -Recurse -Force

Write-Host ''
Write-Host 'Codex Remote Approvals uninstalled.' -ForegroundColor Green
Write-Host 'Fully close and reopen VS Code if it was open after installation so Codex uses the restored CLI setting.' -ForegroundColor Cyan
