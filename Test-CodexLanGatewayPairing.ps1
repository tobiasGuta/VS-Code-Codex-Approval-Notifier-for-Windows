[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$GatewayBaseUrl,
    [Parameter(Mandatory)][ValidatePattern('^\d{6}$')][string]$PairingCode
)

$ErrorActionPreference = 'Stop'

if (-not $GatewayBaseUrl.EndsWith('/')) { $GatewayBaseUrl += '/' }
$uri = [Uri]$GatewayBaseUrl
if ($uri.Scheme -ne 'http') { throw 'Prototype gateway acceptance expects http://.' }
if ([string]::IsNullOrWhiteSpace($uri.Host)) { throw 'Gateway URL has no host.' }

Write-Host '# Codex LAN Gateway Pairing Acceptance'
Write-Host "Gateway: $GatewayBaseUrl"
Write-Host 'Pairing code: supplied out-of-band from gateway console (not displayed)'
Write-Host ''

$status = Invoke-RestMethod -Uri ($GatewayBaseUrl + 'pairing/status') -Method Get -TimeoutSec 5
Write-Host "Pairing available: $($status.pairingAvailable)"
Write-Host "Already paired:    $($status.paired)"
if (-not $status.pairingAvailable -or $status.paired) {
    throw 'Gateway is not in a fresh pairable state. Restart it before this acceptance test.'
}
if ($null -ne $status.pairingCode) { throw 'Pairing status leaked the pairing code.' }
Write-Host 'Pairing status does not reveal code: True'

$unauthorizedRejected = $false
try {
    Invoke-RestMethod -Uri ($GatewayBaseUrl + 'api/status') -Method Get -TimeoutSec 5 | Out-Null
}
catch {
    if ($null -ne $_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 401) { $unauthorizedRejected = $true }
}
Write-Host "Unpaired API request rejected:       $unauthorizedRejected"
if (-not $unauthorizedRejected) { throw 'Gateway accepted an unpaired API request.' }

$badCode = if ($PairingCode -eq '000000') { '000001' } else { '000000' }
$badRejected = $false
try {
    Invoke-RestMethod -Uri ($GatewayBaseUrl + 'pair') -Method Post -Headers @{ 'X-Pairing-Code' = $badCode } -TimeoutSec 5 | Out-Null
}
catch {
    if ($null -ne $_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 401) { $badRejected = $true }
}
Write-Host "Wrong pairing code rejected:         $badRejected"
if (-not $badRejected) { throw 'Gateway accepted an incorrect pairing code.' }

$paired = Invoke-RestMethod -Uri ($GatewayBaseUrl + 'pair') -Method Post -Headers @{ 'X-Pairing-Code' = $PairingCode } -TimeoutSec 5
if (-not $paired.ok -or [string]::IsNullOrWhiteSpace([string]$paired.deviceToken)) {
    throw 'Pairing did not return a device token.'
}
$deviceToken = [string]$paired.deviceToken
Write-Host 'Correct pairing code accepted:       True'
Write-Host 'Device token returned:               True'

$reuseRejected = $false
try {
    Invoke-RestMethod -Uri ($GatewayBaseUrl + 'pair') -Method Post -Headers @{ 'X-Pairing-Code' = $PairingCode } -TimeoutSec 5 | Out-Null
}
catch {
    if ($null -ne $_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 409) { $reuseRejected = $true }
}
Write-Host "Pairing code reuse rejected with 409: $reuseRejected"
if (-not $reuseRejected) { throw 'Pairing code was reusable.' }

$authHeaders = @{ Authorization = "Bearer $deviceToken" }
$apiStatus = Invoke-RestMethod -Uri ($GatewayBaseUrl + 'api/status') -Method Get -Headers $authHeaders -TimeoutSec 5
if (-not $apiStatus.connected) { throw 'Paired gateway reports companion disconnected.' }
Write-Host 'Paired status request:               OK'
Write-Host "Companion connected:                 $($apiStatus.connected)"
Write-Host "Pending count:                       $($apiStatus.pendingCount)"

$approvals = Invoke-RestMethod -Uri ($GatewayBaseUrl + 'api/approvals') -Method Get -Headers $authHeaders -TimeoutSec 5
$data = @($approvals.data)
Write-Host 'Paired approvals request:            OK'
Write-Host "Approvals returned:                  $($data.Count)"

$revoke = Invoke-RestMethod -Uri ($GatewayBaseUrl + 'api/device/revoke') -Method Post -Headers $authHeaders -TimeoutSec 5
if (-not $revoke.ok -or -not $revoke.revoked) { throw 'Device revoke did not succeed.' }
Write-Host 'Self-revoke:                         OK'

$revokedRejected = $false
try {
    Invoke-RestMethod -Uri ($GatewayBaseUrl + 'api/status') -Method Get -Headers $authHeaders -TimeoutSec 5 | Out-Null
}
catch {
    if ($null -ne $_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 401) { $revokedRejected = $true }
}
Write-Host "Revoked token rejected:              $revokedRejected"
if (-not $revokedRejected) { throw 'Revoked device token still authorized API access.' }

Write-Host ''
Write-Host 'PASS: LAN gateway pairing is single-use, paired API access is authenticated, and device revocation is immediate.'
Write-Host 'No Codex approval was accepted or declined by this test.'
