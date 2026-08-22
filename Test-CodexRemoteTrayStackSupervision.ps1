[CmdletBinding()]
param(
    [ValidateRange(2, 30)][int]$TimeoutSeconds = 10
)

$ErrorActionPreference = 'Stop'

function Get-ProcessByNameExact {
    param([Parameter(Mandatory)][string]$Name)
    return @(Get-CimInstance Win32_Process -Filter "Name='$Name'" -ErrorAction Stop)
}

function Get-TrayChild {
    param(
        [Parameter(Mandatory)][int]$TrayPid,
        [Parameter(Mandatory)][string]$Name
    )
    return @(Get-CimInstance Win32_Process -Filter "Name='$Name' AND ParentProcessId=$TrayPid" -ErrorAction Stop)
}

$trays = Get-ProcessByNameExact -Name 'CodexRemoteTray.exe'
if ($trays.Count -ne 1) {
    throw "Expected exactly one CodexRemoteTray.exe process, found $($trays.Count). Start the tray and enable Remote Approvals first."
}
$trayPid = [int]$trays[0].ProcessId

$companion = Get-TrayChild -TrayPid $trayPid -Name 'CodexLocalCompanion.exe'
$gateway = Get-TrayChild -TrayPid $trayPid -Name 'CodexLanGateway.exe'
$mobile = Get-TrayChild -TrayPid $trayPid -Name 'CodexMobileUiServer.exe'

if ($companion.Count -ne 1 -or $gateway.Count -ne 1 -or $mobile.Count -ne 1) {
    throw "Expected exactly one tray-owned companion, gateway, and mobile UI process. Found companion=$($companion.Count), gateway=$($gateway.Count), mobile=$($mobile.Count)."
}

$companionPid = [int]$companion[0].ProcessId
$gatewayPid = [int]$gateway[0].ProcessId
$mobilePid = [int]$mobile[0].ProcessId

Write-Host '# Codex Remote Tray Stack Supervision Acceptance'
Write-Host "Tray PID:      $trayPid"
Write-Host "Companion PID: $companionPid"
Write-Host "Gateway PID:   $gatewayPid"
Write-Host "Mobile UI PID: $mobilePid"
Write-Host ''
Write-Host 'Hard-killing only the tray-owned mobile UI process...'

Stop-Process -Id $mobilePid -Force -ErrorAction Stop

$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$companionGone = $false
$gatewayGone = $false
$mobileGone = $false
while ([DateTime]::UtcNow -lt $deadline) {
    $companionGone = $null -eq (Get-Process -Id $companionPid -ErrorAction SilentlyContinue)
    $gatewayGone = $null -eq (Get-Process -Id $gatewayPid -ErrorAction SilentlyContinue)
    $mobileGone = $null -eq (Get-Process -Id $mobilePid -ErrorAction SilentlyContinue)
    if ($companionGone -and $gatewayGone -and $mobileGone) { break }
    Start-Sleep -Milliseconds 100
}

$trayStillRunning = $null -ne (Get-Process -Id $trayPid -ErrorAction SilentlyContinue)

Write-Host "Mobile UI terminated:             $mobileGone"
Write-Host "Companion torn down by tray:      $companionGone"
Write-Host "Gateway torn down by tray:        $gatewayGone"
Write-Host "Tray remains available to re-enable: $trayStillRunning"

if (-not $mobileGone) { throw 'The mobile UI process did not terminate.' }
if (-not $companionGone -or -not $gatewayGone) { throw 'The tray did not fail closed by tearing down the remaining remote-approval stack.' }
if (-not $trayStillRunning) { throw 'The tray exited instead of remaining available for an explicit re-enable.' }

Write-Host ''
Write-Host 'PASS: an unexpected tray-owned child exit tears down the full remote-approval stack while leaving the tray available.' -ForegroundColor Green
Write-Host 'Visual confirmation: the tray menu should no longer say "Remote approvals are on"; Pair/Disable should be unavailable and Enable should be available.'
