[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BaseUrl
)

$ErrorActionPreference = 'Stop'
if (-not $BaseUrl.EndsWith('/')) { $BaseUrl += '/' }

Write-Host '# Codex Mobile UI Server Smoke Test'
Write-Host "Base: $BaseUrl"
Write-Host ''

$web = Invoke-WebRequest -Uri $BaseUrl -Method Get -TimeoutSec 5
if ($web.StatusCode -ne 200) { throw "Root returned HTTP $($web.StatusCode)." }
if ($web.Content -notmatch 'Codex Remote Approval') { throw 'Root page did not contain the expected mobile UI title.' }
$csp = [string]$web.Headers['Content-Security-Policy']
if ([string]::IsNullOrWhiteSpace($csp) -or $csp -notmatch "script-src 'self'" -or $csp -notmatch "connect-src 'self'") {
    throw 'Root page is missing the expected strict Content-Security-Policy.'
}
Write-Host 'Root mobile page:                 OK'
Write-Host 'Strict CSP present:               True'

$js = Invoke-WebRequest -Uri ($BaseUrl + 'app.js') -Method Get -TimeoutSec 5
if ($js.StatusCode -ne 200 -or $js.Content -notmatch 'sessionStorage') { throw 'app.js did not load as expected.' }
Write-Host 'JavaScript asset:                 OK'

$css = Invoke-WebRequest -Uri ($BaseUrl + 'app.css') -Method Get -TimeoutSec 5
if ($css.StatusCode -ne 200 -or $css.Content -notmatch 'approval-card') { throw 'app.css did not load as expected.' }
Write-Host 'Stylesheet asset:                 OK'

$pairStatus = Invoke-RestMethod -Uri ($BaseUrl + 'pairing/status') -Method Get -TimeoutSec 5
Write-Host "Pairing status proxy:             OK"
Write-Host "Pairing available:                $($pairStatus.pairingAvailable)"
Write-Host "Already paired:                   $($pairStatus.paired)"

$unauthorizedRejected = $false
try {
    Invoke-RestMethod -Uri ($BaseUrl + 'api/status') -Method Get -TimeoutSec 5 | Out-Null
}
catch {
    if ($null -ne $_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 401) {
        $unauthorizedRejected = $true
    }
}
Write-Host "Unauthenticated API rejected:      $unauthorizedRejected"
if (-not $unauthorizedRejected) { throw 'Mobile UI proxy allowed unauthenticated API access.' }

Write-Host ''
Write-Host 'PASS: mobile UI assets are served with a strict CSP and the same-origin proxy preserves LAN gateway authentication.'
Write-Host 'This test did not pair a device or resolve any Codex approval.'
