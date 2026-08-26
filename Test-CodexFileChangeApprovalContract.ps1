[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

Write-Host '# Codex File-Change Approval Contract Test'
Write-Host ''

& (Join-Path $PSScriptRoot 'BuildCodexLocalCompanion.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Companion build failed.' }

$source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'CodexLocalCompanion.cs') -Raw -Encoding UTF8
$app = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'mobile\app.js') -Raw -Encoding UTF8
$html = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'mobile\index.html') -Raw -Encoding UTF8

$requiredSource = @(
    'item/fileChange/requestApproval',
    'item/fileChange/patchUpdated',
    '"kind", a.Kind == ApprovalKind.Command ? "command" : "fileChange"',
    'allowOnceAvailable',
    'allow_unavailable',
    'EvidenceChangedSinceClaim',
    'MaxFileEvidenceBytes',
    'MaxFileChangeCount'
)
foreach ($needle in $requiredSource) {
    if (-not $source.Contains($needle)) { throw "Missing file-change approval invariant: $needle" }
}

$forbiddenSource = @(
    'acceptForSession',
    'grantRoot',
    'turn/diff/updated'
)
foreach ($needle in $forbiddenSource) {
    if ($source.Contains($needle)) { throw "Forbidden remote capability/evidence source present: $needle" }
}

if (-not $app.Contains("approval.kind === 'fileChange'")) { throw 'Mobile renderer does not branch explicitly on fileChange approvals.' }
if (-not $app.Contains('approval.allowOnceAvailable === true')) { throw 'Mobile renderer does not fail closed on Allow once availability.' }
if (-not $app.Contains('textContent = change.diff')) { throw 'Mobile renderer does not render native diff as text.' }
if ($app.Contains('innerHTML')) { throw 'Mobile renderer must not inject file-change evidence as HTML.' }
if (-not $html.Contains('file-details') -or -not $app.Contains("kindBadge.textContent = 'FILE CHANGE'")) { throw 'Mobile UI does not label file-change approvals distinctly.' }

Write-Host 'Companion build:                 PASS'
Write-Host 'Native file-change methods:      PASS'
Write-Host 'Allow-once fail-closed guard:    PASS'
Write-Host 'Session-wide grants excluded:    PASS'
Write-Host 'Aggregate turn diff excluded:    PASS'
Write-Host 'Text-only mobile rendering:      PASS'
Write-Host ''
Write-Host 'PASS: file-change approval contract is constrained to native one-time accept/decline semantics.'
