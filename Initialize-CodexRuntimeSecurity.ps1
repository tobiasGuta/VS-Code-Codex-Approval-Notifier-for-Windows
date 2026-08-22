[CmdletBinding()]
param(
    [string]$Root = (Join-Path $env:LOCALAPPDATA 'CodexApprovalNotifier')
)

$ErrorActionPreference = 'Stop'

# Do not rely on PSModulePath/autoload here. Setup is often launched from
# PowerShell 7 but deliberately invokes Windows PowerShell 5.1 for configuration;
# the child process can inherit a module search path from its parent shell. Load
# the Security module that belongs to the current PowerShell host explicitly.
$securityModuleManifest = [IO.Path]::Combine(
    $PSHOME,
    'Modules',
    'Microsoft.PowerShell.Security',
    'Microsoft.PowerShell.Security.psd1'
)
if (-not [IO.File]::Exists($securityModuleManifest)) {
    throw "Microsoft.PowerShell.Security was not found for this PowerShell host: $securityModuleManifest"
}
Import-Module -Name $securityModuleManifest -Force -ErrorAction Stop

$icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
if (-not (Test-Path -LiteralPath $icacls -PathType Leaf)) {
    throw "Windows ACL utility was not found: $icacls"
}

$currentUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
if ($null -eq $currentUserSid) { throw 'Could not resolve the current Windows user SID.' }
$currentUserSidValue = $currentUserSid.Value
$systemSidValue = 'S-1-5-18'
$administratorsSidValue = 'S-1-5-32-544'

function Invoke-Icacls {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $output = @(& $script:icacls $Path @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $detail = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = "icacls exit code $LASTEXITCODE" }
        throw "Could not harden runtime ACL for ${Path}: $detail"
    }
}

function Get-SidValue($IdentityReference) {
    if ($IdentityReference -is [Security.Principal.SecurityIdentifier]) { return $IdentityReference.Value }
    return $IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
}

function Assert-RuntimeAcl {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][bool]$IsDirectory
    )

    $acl = Get-Acl -LiteralPath $Path
    if (-not $acl.AreAccessRulesProtected) {
        throw "Runtime ACL inheritance is not blocked: $Path"
    }

    $expected = @($script:currentUserSidValue, $script:systemSidValue, $script:administratorsSidValue) | Sort-Object -Unique
    $rules = @($acl.Access)
    if ($rules.Count -ne 3) {
        throw "Runtime ACL has unexpected access rules on $Path; expected exactly three, found $($rules.Count)."
    }

    $actual = @()
    foreach ($rule in $rules) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) {
            throw "Runtime ACL contains a deny rule on $Path."
        }
        if ($rule.IsInherited) {
            throw "Runtime ACL still contains an inherited rule on ${Path}: $($rule.IdentityReference)"
        }

        $full = [Security.AccessControl.FileSystemRights]::FullControl
        if (($rule.FileSystemRights -band $full) -ne $full) {
            throw "Runtime ACL rule is not FullControl on ${Path}: $($rule.IdentityReference)"
        }

        if ($IsDirectory) {
            $needed = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
            if (($rule.InheritanceFlags -band $needed) -ne $needed) {
                throw "Runtime directory rule does not propagate to children on ${Path}: $($rule.IdentityReference)"
            }
        }

        $actual += Get-SidValue $rule.IdentityReference
    }

    $actual = $actual | Sort-Object -Unique
    if (@(Compare-Object $expected $actual).Count -ne 0) {
        throw "Runtime ACL principals differ from current-user/SYSTEM/Administrators on $Path."
    }
}

function Protect-RuntimeFile([string]$Path) {
    $grants = @(
        '/inheritance:r',
        '/grant:r',
        ('*{0}:F' -f $script:currentUserSidValue),
        ('*{0}:F' -f $script:systemSidValue),
        ('*{0}:F' -f $script:administratorsSidValue)
    )
    Invoke-Icacls -Path $Path -Arguments $grants
    Assert-RuntimeAcl -Path $Path -IsDirectory $false
}

function Protect-RuntimeDirectory([string]$Path) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null

    # icacls is available on supported Windows versions and works consistently
    # from both PowerShell 7 and Windows PowerShell 5.1. We modify only the DACL:
    # inherited ACEs are removed and exactly three explicit FullControl grants are
    # installed. No SACL/audit privilege is requested, so this remains per-user.
    $grants = @(
        '/inheritance:r',
        '/grant:r',
        ('*{0}:(OI)(CI)F' -f $script:currentUserSidValue),
        ('*{0}:(OI)(CI)F' -f $script:systemSidValue),
        ('*{0}:(OI)(CI)F' -f $script:administratorsSidValue)
    )
    Invoke-Icacls -Path $Path -Arguments $grants
    Assert-RuntimeAcl -Path $Path -IsDirectory $true

    foreach ($file in @(Get-ChildItem -LiteralPath $Path -File -ErrorAction SilentlyContinue)) {
        Protect-RuntimeFile -Path $file.FullName
    }
}

function Test-RuntimeArtifactStale {
    param(
        [Parameter(Mandatory)][IO.FileInfo]$File,
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$ExpectedProcessName
    )

    $match = [regex]::Match($File.Name, ('^{0}-(?<pid>[1-9][0-9]*)\.(?:json|token)$' -f [regex]::Escape($Prefix)))
    if (-not $match.Success) { return $false }

    $pidValue = [int]$match.Groups['pid'].Value
    $process = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $true }
    if (-not [string]::Equals($process.ProcessName, $ExpectedProcessName, [StringComparison]::OrdinalIgnoreCase)) { return $true }

    try {
        # A process instance that started after this runtime artifact cannot be the
        # process instance that originally created it. A one-second tolerance avoids
        # false positives from filesystem timestamp granularity.
        if ($process.StartTime.ToUniversalTime() -gt $File.LastWriteTimeUtc.AddSeconds(1)) { return $true }
    }
    catch {
        return $true
    }

    return $false
}

function Remove-StaleRuntimeArtifacts {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$ExpectedProcessName
    )

    foreach ($file in @(Get-ChildItem -LiteralPath $Path -File -ErrorAction SilentlyContinue)) {
        if (Test-RuntimeArtifactStale -File $file -Prefix $Prefix -ExpectedProcessName $ExpectedProcessName) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
        }
    }
}

$Root = [IO.Path]::GetFullPath($Root)
$targets = @(
    [pscustomobject]@{ Name='local-bridge'; Prefix='bridge'; ExpectedProcess='CodexAppServerShim' },
    [pscustomobject]@{ Name='companion'; Prefix='companion'; ExpectedProcess='CodexLocalCompanion' },
    [pscustomobject]@{ Name='lan-gateway'; Prefix='gateway'; ExpectedProcess='CodexLanGateway' }
)

foreach ($target in $targets) {
    $path = Join-Path $Root $target.Name
    Protect-RuntimeDirectory -Path $path
    Remove-StaleRuntimeArtifacts -Path $path -Prefix $target.Prefix -ExpectedProcessName $target.ExpectedProcess
}

Write-Host 'Codex runtime security initialized.'
Write-Host "Root: $Root"
Write-Host 'Protected: local-bridge, companion, lan-gateway'
Write-Host 'ACL: current user + SYSTEM + Administrators (FullControl); inheritance blocked'
