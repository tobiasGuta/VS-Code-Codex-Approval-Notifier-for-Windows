[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'

$installDir = Join-Path $env:LOCALAPPDATA 'CodexApprovalNotifier'
$programsDir = [Environment]::GetFolderPath('Programs')
$startupDir = [Environment]::GetFolderPath('Startup')
$identityShortcut = Join-Path $programsDir 'Codex Approval Notifier.lnk'
$startupShortcut = Join-Path $startupDir 'Codex Approval Notifier.lnk'
$protocolRoot = 'HKCU:\Software\Classes\codexapproval'

Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like "*$installDir*CodexApprovalNotifier.ps1*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Start-Sleep -Milliseconds 300

Remove-Item -LiteralPath $startupShortcut -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $identityShortcut -Force -ErrorAction SilentlyContinue
Remove-Item -Path $protocolRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host 'Codex Approval Notifier uninstalled.' -ForegroundColor Green
