[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-SidValue($IdentityReference) {
    if ($IdentityReference -is [Security.Principal.SecurityIdentifier]) { return $IdentityReference.Value }
    return $IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
}

function Assert-ProtectedAcl([string]$Path, [bool]$IsDirectory) {
    $acl = Get-Acl -LiteralPath $Path
    if (-not $acl.AreAccessRulesProtected) { throw "ACL inheritance is not blocked: $Path" }

    $expected = @(
        [Security.Principal.WindowsIdentity]::GetCurrent().User.Value,
        'S-1-5-18',
        'S-1-5-32-544'
    ) | Sort-Object -Unique

    $rules = @($acl.Access)
    if ($rules.Count -ne 3) { throw "Expected exactly three access rules on $Path; found $($rules.Count)." }

    $actual = @()
    foreach ($rule in $rules) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) {
            throw "Unexpected deny rule on $Path"
        }

        $fullControl = [Security.AccessControl.FileSystemRights]::FullControl
        $hasFullControl = (($rule.FileSystemRights -band $fullControl) -eq $fullControl)
        if (-not $hasFullControl) {
            throw "Rule is not FullControl on ${Path}: $($rule.IdentityReference)"
        }

        if ($rule.IsInherited) { throw "Inherited rule survived on ${Path}: $($rule.IdentityReference)" }
        $actual += Get-SidValue $rule.IdentityReference
    }

    $actual = $actual | Sort-Object -Unique
    if (@(Compare-Object $expected $actual).Count -ne 0) {
        throw "ACL principals differ from current-user/SYSTEM/Administrators on $Path"
    }

    if ($IsDirectory) {
        foreach ($rule in $rules) {
            $needed = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
            if (($rule.InheritanceFlags -band $needed) -ne $needed) {
                throw "Directory rule does not propagate to child objects on ${Path}: $($rule.IdentityReference)"
            }
        }
    }
}

$root = Join-Path $env:TEMP ('CodexRuntimeSecurityAcceptance-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $root -Force | Out-Null

    $cases = @(
        [pscustomobject]@{ Directory='local-bridge'; Prefix='bridge'; Token=$true },
        [pscustomobject]@{ Directory='companion'; Prefix='companion'; Token=$true },
        [pscustomobject]@{ Directory='lan-gateway'; Prefix='gateway'; Token=$false }
    )

    foreach ($case in $cases) {
        $dir = Join-Path $root $case.Directory
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir ($case.Prefix + '-2147483000.json')) -Value '{}' -Encoding ASCII
        if ($case.Token) {
            Set-Content -LiteralPath (Join-Path $dir ($case.Prefix + '-2147483000.token')) -Value 'synthetic-not-a-real-token' -Encoding ASCII
        }
        Set-Content -LiteralPath (Join-Path $dir 'keep.txt') -Value 'keep' -Encoding ASCII
    }

    & (Join-Path $PSScriptRoot 'Initialize-CodexRuntimeSecurity.ps1') -Root $root

    Write-Host '# Codex Runtime Security Acceptance'
    foreach ($case in $cases) {
        $dir = Join-Path $root $case.Directory
        Assert-ProtectedAcl -Path $dir -IsDirectory $true
        Assert-ProtectedAcl -Path (Join-Path $dir 'keep.txt') -IsDirectory $false

        $staleJson = Join-Path $dir ($case.Prefix + '-2147483000.json')
        if (Test-Path -LiteralPath $staleJson) { throw "Synthetic stale descriptor survived: $staleJson" }
        if ($case.Token) {
            $staleToken = Join-Path $dir ($case.Prefix + '-2147483000.token')
            if (Test-Path -LiteralPath $staleToken) { throw "Synthetic stale token survived: $staleToken" }
        }
        if (-not (Test-Path -LiteralPath (Join-Path $dir 'keep.txt'))) { throw "Unrelated file was deleted in $dir" }

        Write-Host ("{0,-14} protected ACL: PASS; stale cleanup: PASS" -f $case.Directory)
    }

    Write-Host ''
    Write-Host 'PASS: sensitive runtime directories are inheritance-protected and stale runtime credentials are removed without deleting unrelated files.' -ForegroundColor Green
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
