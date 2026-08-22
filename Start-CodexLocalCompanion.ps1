[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ThreadId,
    [int]$Port = 8765,
    [ValidateRange(5, 3600)][int]$ApprovalTtlSeconds = 300,
    [string]$CompanionPath = (Join-Path $PSScriptRoot 'companion-build\CodexLocalCompanion.exe'),
    [string]$DescriptorPath
)

$ErrorActionPreference = 'Stop'

function Get-BridgeRuntimeDirectory {
    return (Join-Path $env:LOCALAPPDATA 'CodexApprovalNotifier\local-bridge')
}

function Convert-DescriptorCreatedAtToDateTimeOffset($Value) {
    if ($null -eq $Value) { throw 'Bridge descriptor is missing createdAt.' }
    if ($Value -is [DateTimeOffset]) { return [DateTimeOffset]$Value }
    if ($Value -is [DateTime]) { return [DateTimeOffset]([DateTime]$Value) }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { throw 'Bridge descriptor is missing createdAt.' }
    return [DateTimeOffset]::Parse(
        $text,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind)
}

function Test-BridgeDescriptorIdentity {
    param(
        [Parameter(Mandatory)]$Descriptor,
        [Parameter(Mandatory)][string]$Path,
        [switch]$ThrowOnFailure
    )

    try {
        $shimPid = [int]$Descriptor.shimPid
        $codexPid = [int]$Descriptor.codexPid
        if ($shimPid -le 0 -or $codexPid -le 0) { throw 'Bridge descriptor contains an invalid process id.' }

        $createdAt = Convert-DescriptorCreatedAtToDateTimeOffset $Descriptor.createdAt

        $runtimeDir = [IO.Path]::GetFullPath((Get-BridgeRuntimeDirectory)).TrimEnd('\')
        $actualDescriptor = [IO.Path]::GetFullPath($Path)
        $expectedDescriptor = [IO.Path]::GetFullPath((Join-Path $runtimeDir "bridge-$shimPid.json"))
        if (-not [string]::Equals($actualDescriptor, $expectedDescriptor, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Bridge descriptor path does not match its shim PID.'
        }

        $tokenPath = [string]$Descriptor.tokenFile
        if ([string]::IsNullOrWhiteSpace($tokenPath)) { throw 'Bridge descriptor is missing tokenFile.' }
        $actualToken = [IO.Path]::GetFullPath($tokenPath)
        $expectedToken = [IO.Path]::GetFullPath((Join-Path $runtimeDir "bridge-$shimPid.token"))
        if (-not [string]::Equals($actualToken, $expectedToken, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Bridge token path does not match its shim PID.'
        }

        $shim = Get-Process -Id $shimPid -ErrorAction Stop
        $codex = Get-Process -Id $codexPid -ErrorAction Stop
        $shimStarted = [DateTimeOffset]$shim.StartTime
        $codexStarted = [DateTimeOffset]$codex.StartTime
        if ($shimStarted.UtcDateTime -gt $createdAt.UtcDateTime) {
            throw 'Bridge shim PID belongs to a process that started after the descriptor was created.'
        }
        if ($codexStarted.UtcDateTime -gt $createdAt.UtcDateTime) {
            throw 'Bridge Codex PID belongs to a process that started after the descriptor was created.'
        }
        return $true
    }
    catch {
        if ($ThrowOnFailure) { throw }
        return $false
    }
}

if (-not (Test-Path -LiteralPath $CompanionPath -PathType Leaf)) {
    throw "Companion executable not found: $CompanionPath"
}
$CompanionPath = (Resolve-Path -LiteralPath $CompanionPath).Path

if ([string]::IsNullOrWhiteSpace($DescriptorPath)) {
    $runtimeDir = Get-BridgeRuntimeDirectory
    $candidates = @(Get-ChildItem -LiteralPath $runtimeDir -Filter 'bridge-*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending)

    foreach ($candidate in $candidates) {
        try {
            $d = Get-Content -LiteralPath $candidate.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            if (Test-BridgeDescriptorIdentity -Descriptor $d -Path $candidate.FullName) {
                $DescriptorPath = $candidate.FullName
                break
            }
        }
        catch { }
    }
}

if ([string]::IsNullOrWhiteSpace($DescriptorPath) -or -not (Test-Path -LiteralPath $DescriptorPath -PathType Leaf)) {
    throw 'No live local-bridge descriptor was found.'
}
$DescriptorPath = (Resolve-Path -LiteralPath $DescriptorPath).Path
$descriptor = Get-Content -LiteralPath $DescriptorPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
$null = Test-BridgeDescriptorIdentity -Descriptor $descriptor -Path $DescriptorPath -ThrowOnFailure

Write-Host 'Starting Codex Local Companion...'
Write-Host "Thread:       $ThreadId"
Write-Host "Bridge:       $DescriptorPath"
Write-Host "HTTP port:    $Port"
Write-Host "Approval TTL: $ApprovalTtlSeconds seconds"
Write-Host ''

& $CompanionPath --descriptor $DescriptorPath --thread $ThreadId --port $Port --approval-ttl-seconds $ApprovalTtlSeconds
exit $LASTEXITCODE
