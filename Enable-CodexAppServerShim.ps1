[CmdletBinding()]
param(
    [ValidateSet('passthrough', 'remote-control')]
    [string]$Mode = 'passthrough',
    [string]$ShimPath = (Join-Path $PSScriptRoot 'shim-build\CodexAppServerShim.exe')
)

$ErrorActionPreference = 'Stop'

$shim = (Resolve-Path -LiteralPath $ShimPath).Path
if (-not (Test-Path -LiteralPath $shim -PathType Leaf)) {
    throw "Shim executable not found: $ShimPath"
}

$shimDirectory = Split-Path -Parent $shim
$modePath = Join-Path $shimDirectory 'CodexAppServerShim.mode'

$settingsPath = Join-Path $env:APPDATA 'Code\User\settings.json'
if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    throw "VS Code user settings file not found: $settingsPath"
}

$text = [IO.File]::ReadAllText($settingsPath)
if ($text -match '(?m)^\s*["'']chatgpt\.cliExecutable["'']\s*:') {
    throw 'chatgpt.cliExecutable already exists in VS Code user settings. Refusing to overwrite it.'
}

$stateDir = Join-Path $env:LOCALAPPDATA 'CodexApprovalNotifier\shim-acceptance'
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
$backupPath = Join-Path $stateDir 'settings.before-shim.json'
$statePath = Join-Path $stateDir 'state.json'

if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    throw "A shim acceptance state already exists: $statePath. Run Disable-CodexAppServerShim.ps1 first."
}

Copy-Item -LiteralPath $settingsPath -Destination $backupPath -Force
Set-Content -LiteralPath $modePath -Value $Mode -Encoding ASCII

$jsonShim = $shim.Replace('\', '\\').Replace('"', '\"')
$insertion = "`r`n    // TEMP: Codex Approval Notifier app-server shim acceptance`r`n    `"chatgpt.cliExecutable`": `"$jsonShim`"," 

$openBrace = $text.IndexOf('{')
if ($openBrace -lt 0) {
    Remove-Item -LiteralPath $modePath -Force -ErrorAction SilentlyContinue
    throw 'VS Code settings.json does not contain a top-level opening brace.'
}

$updated = $text.Insert($openBrace + 1, $insertion)
[IO.File]::WriteAllText($settingsPath, $updated, (New-Object Text.UTF8Encoding($false)))

$state = [ordered]@{
    version = 2
    enabledAt = [DateTimeOffset]::Now.ToString('o')
    settingsPath = $settingsPath
    backupPath = $backupPath
    shimPath = $shim
    modePath = $modePath
    mode = $Mode
}
$state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8

Write-Host 'Temporary Codex app-server shim setting enabled.'
Write-Host "Mode:     $Mode"
Write-Host "Settings: $settingsPath"
Write-Host "Shim:     $shim"
Write-Host "Backup:   $backupPath"
Write-Host ''
Write-Host 'NEXT: Save any work, fully close all VS Code windows, then reopen VS Code.'
Write-Host 'Rollback: .\Disable-CodexAppServerShim.ps1'
