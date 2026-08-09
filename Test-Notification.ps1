$ErrorActionPreference = 'Stop'

$watcher = Join-Path $PSScriptRoot 'CodexApprovalNotifier.ps1'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

if (-not (Test-Path -LiteralPath $windowsPowerShell)) {
    throw "Windows PowerShell 5.1 was not found at: $windowsPowerShell"
}

& $windowsPowerShell -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File $watcher -TestNotification
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    throw "Native notification test failed with exit code $exitCode."
}
