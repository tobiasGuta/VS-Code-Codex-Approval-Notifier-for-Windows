[CmdletBinding()]
param(
    [string]$Root = (Join-Path $env:LOCALAPPDATA 'CodexApprovalNotifier')
)

$ErrorActionPreference = 'Stop'

function New-ProtectedDirectorySecurity {
    $current = [Security.Principal.WindowsIdentity]::GetCurrent().User
    if ($null -eq $current) { throw 'Could not resolve the current Windows user SID.' }

    $system = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $admins = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')

    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetOwner($current)
    $acl.SetAccessRuleProtection($true, $false)

    $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagate = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $full = [Security.AccessControl.FileSystemRights]::FullControl

    foreach ($sid in @($current, $system, $admins)) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, $full, $inherit, $propagate, $allow)
        $acl.AddAccessRule($rule)
    }

    return $acl
}

function New-ProtectedFileSecurity {
    $current = [Security.Principal.WindowsIdentity]::GetCurrent().User
    if ($null -eq $current) { throw 'Could not resolve the current Windows user SID.' }

    $system = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $admins = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')

    $acl = New-Object Security.AccessControl.FileSecurity
    $acl.SetOwner($current)
    $acl.SetAccessRuleProtection($true, $false)

    $allow = [Security.AccessControl.AccessControlType]::Allow
    $full = [Security.AccessControl.FileSystemRights]::FullControl

    foreach ($sid in @($current, $system, $admins)) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, $full, $allow)
        $acl.AddAccessRule($rule)
    }

    return $acl
}

function Protect-RuntimeDirectory([string]$Path) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    Set-Acl -LiteralPath $Path -AclObject (New-ProtectedDirectorySecurity)

    foreach ($file in @(Get-ChildItem -LiteralPath $Path -File -ErrorAction SilentlyContinue)) {
        Set-Acl -LiteralPath $file.FullName -AclObject (New-ProtectedFileSecurity)
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
