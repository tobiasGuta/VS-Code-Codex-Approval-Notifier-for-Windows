[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('passthrough', 'remote-control')]
    [string]$Mode
)

$ErrorActionPreference = 'Stop'

$stateDir = Join-Path $env:LOCALAPPDATA 'CodexApprovalNotifier\shim-acceptance'
$statePath = Join-Path $stateDir 'state.json'
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    throw 'No active shim acceptance state was found. Run Enable-CodexAppServerShim.ps1 first.'
}

$state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
$shimPath = [string]$state.shimPath
$modePath = [string]$state.modePath

if ([string]::IsNullOrWhiteSpace($shimPath) -or -not (Test-Path -LiteralPath $shimPath -PathType Leaf)) {
    throw "Active shim executable was not found: $shimPath"
}
if ([string]::IsNullOrWhiteSpace($modePath)) {
    throw 'The active acceptance state does not contain a mode path. Disable the old state and enable the shim again.'
}

Set-Content -LiteralPath $modePath -Value $Mode -Encoding ASCII

$state.mode = $Mode
$state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8

Write-Host 'Codex app-server shim mode changed.'
Write-Host "Mode: $Mode"
Write-Host "Shim: $shimPath"
Write-Host ''
Write-Host 'The currently running Codex process is unchanged.'
Write-Host 'Fully close all VS Code windows and reopen VS Code for this mode to take effect.'
Write-Host 'Rollback: .\Disable-CodexAppServerShim.ps1'
