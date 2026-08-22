[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$stateDir = Join-Path $env:LOCALAPPDATA 'CodexApprovalNotifier\shim-acceptance'
$statePath = Join-Path $stateDir 'state.json'
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    Write-Host 'No shim acceptance state was found; nothing to restore.'
    exit 0
}

$state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
$settingsPath = [string]$state.settingsPath
$backupPath = [string]$state.backupPath
$modePath = [string]$state.modePath

if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
    throw "Shim settings backup not found: $backupPath"
}

Copy-Item -LiteralPath $backupPath -Destination $settingsPath -Force
if (-not [string]::IsNullOrWhiteSpace($modePath)) {
    Remove-Item -LiteralPath $modePath -Force -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath $statePath -Force
Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue

Write-Host 'Original VS Code user settings restored.'
Write-Host "Settings: $settingsPath"
Write-Host ''
Write-Host 'Fully close all VS Code windows and reopen VS Code to return to the normal Codex executable.'
