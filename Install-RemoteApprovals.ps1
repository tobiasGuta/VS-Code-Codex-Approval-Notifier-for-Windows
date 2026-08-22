[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Find-Csc {
    foreach ($p in @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )) { if (Test-Path -LiteralPath $p -PathType Leaf) { return $p } }
    throw 'Windows .NET Framework C# compiler was not found.'
}

function Find-InstalledCodexBinary {
    $extensions = Join-Path $env:USERPROFILE '.vscode\extensions'
    if (-not (Test-Path -LiteralPath $extensions -PathType Container)) {
        throw 'VS Code extensions directory was not found. Install the OpenAI Codex extension first.'
    }
    $candidates = @(
        Get-ChildItem -LiteralPath $extensions -Directory -Filter 'openai.chatgpt-*-win32-x64' -ErrorAction SilentlyContinue |
        ForEach-Object {
            $codex = Join-Path $_.FullName 'bin\windows-x86_64\codex.exe'
            if (Test-Path -LiteralPath $codex -PathType Leaf) {
                [pscustomobject]@{ Path=$codex; Stamp=$_.LastWriteTimeUtc }
            }
        } |
        Sort-Object Stamp -Descending
    )
    if ($candidates.Count -eq 0) { throw 'No installed Windows x64 OpenAI Codex extension binary was found.' }
    return [string]$candidates[0].Path
}

function Invoke-Build([string]$Script, [hashtable]$Named) {
    $path = Join-Path $sourceDir $Script
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing build script: $Script" }
    $args = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$path)
    foreach ($key in $Named.Keys) { $args += @("-$key", [string]$Named[$key]) }
    $output = @(& $windowsPowerShell @args 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw "$Script failed.`r`n$($output -join "`r`n")" }
}

function Get-CliExecutableValue([string]$Text) {
    $m = [regex]::Match($Text, '(?m)^\s*["'']chatgpt\.cliExecutable["'']\s*:\s*["''](?<v>[^"'']+)["'']\s*,?\s*(?://.*)?$')
    if (-not $m.Success) { return $null }
    return $m.Groups['v'].Value.Replace('\\','\')
}

function Is-RecognizedPrototypeShim([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        $full = [IO.Path]::GetFullPath($Path)
        if ([IO.Path]::GetFileName($full) -ne 'CodexAppServerShim.exe') { return $false }
        $dir = Split-Path -Parent $full
        $target = Join-Path $dir 'CodexAppServerShim.target'
        $mode = Join-Path $dir 'CodexAppServerShim.mode'
        if (-not (Test-Path -LiteralPath $full -PathType Leaf) -or -not (Test-Path -LiteralPath $target -PathType Leaf)) { return $false }
        if (Test-Path -LiteralPath $mode -PathType Leaf) {
            $m = (Get-Content -LiteralPath $mode -Raw -Encoding UTF8).Trim()
            if ($m -notin @('local-bridge','passthrough','remote-control')) { return $false }
        }
        $t = (Get-Content -LiteralPath $target -Raw -Encoding UTF8).Trim().Trim('"')
        return $t -match '(?i)\\\.vscode\\extensions\\openai\.chatgpt-[^\\]+\\bin\\windows-x86_64\\codex\.exe$'
    } catch { return $false }
}

function Set-InstallerCliSetting([string]$SettingsPath, [string]$InstalledShim) {
    $text = if (Test-Path -LiteralPath $SettingsPath -PathType Leaf) { [IO.File]::ReadAllText($SettingsPath) } else { "{`r`n}`r`n" }
    $existing = Get-CliExecutableValue $text
    $state = [ordered]@{ previousCliExecutable=$null; added=$false; migrated=$false }
    $jsonShim = $InstalledShim.Replace('\','\\').Replace('"','\"')

    if ([string]::IsNullOrWhiteSpace($existing)) {
        $brace = $text.IndexOf('{')
        if ($brace -lt 0) { throw 'VS Code settings.json does not contain a top-level opening brace.' }
        $insertion = "`r`n    // Codex Approval Notifier Remote Approvals`r`n    `"chatgpt.cliExecutable`": `"$jsonShim`"," 
        $text = $text.Insert($brace + 1, $insertion)
        $state.added = $true
    }
    elseif (Is-RecognizedPrototypeShim $existing) {
        $state.previousCliExecutable = $existing
        $state.migrated = $true
        $pattern = '(?m)^(?<indent>\s*)["'']chatgpt\.cliExecutable["'']\s*:\s*["''][^"'']+["''](?<tail>\s*,?\s*(?://.*)?)$'
        $text = [regex]::Replace($text, $pattern, '${indent}"chatgpt.cliExecutable": "' + $jsonShim + '"${tail}', 1)
    }
    else {
        throw "VS Code already has a custom chatgpt.cliExecutable setting that this installer does not own: $existing"
    }

    $parent = Split-Path -Parent $SettingsPath
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    [IO.File]::WriteAllText($SettingsPath, $text, (New-Object Text.UTF8Encoding($false)))
    return $state
}

$sourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) { throw 'Windows PowerShell 5.1 is required.' }
$null = Find-Csc

if (@(Get-Process -Name Code -ErrorAction SilentlyContinue).Count -gt 0) {
    throw 'Close all VS Code windows before installing Remote Approvals. The installer will not terminate VS Code for you.'
}

$required = @(
    'CodexAppServerShim.cs','BuildCodexAppServerShim.ps1',
    'CodexLocalCompanion.cs','BuildCodexLocalCompanion.ps1',
    'CodexLanGateway.cs','BuildCodexLanGateway.ps1',
    'CodexMobileUiServer.cs','BuildCodexMobileUiServer.ps1',
    'CodexRemoteTray.cs','QrCodeV4.cs','BuildCodexRemoteTray.ps1',
    'Select-CodexLiveThread.ps1','Uninstall-RemoteApprovals.ps1',
    'mobile\index.html','mobile\app.js','mobile\app.css'
)
foreach ($rel in $required) { if (-not (Test-Path -LiteralPath (Join-Path $sourceDir $rel))) { throw "Installer source is incomplete: $rel" } }

$installDir = Join-Path $env:LOCALAPPDATA 'CodexApprovalNotifier\remote'
$stageDir = Join-Path $env:TEMP ('CodexRemoteApprovals-' + [guid]::NewGuid().ToString('N'))
$settingsPath = Join-Path $env:APPDATA 'Code\User\settings.json'
$startupDir = [Environment]::GetFolderPath('Startup')
$startupShortcut = Join-Path $startupDir 'Codex Remote Approvals.lnk'
$statePath = Join-Path $installDir 'install-state.json'

if (Test-Path -LiteralPath $statePath -PathType Leaf) { throw 'Remote Approvals is already installed. Uninstall it before reinstalling this prototype.' }

try {
    New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
    $codexTarget = Find-InstalledCodexBinary
    Write-Host "Detected Codex extension: $codexTarget"

    Invoke-Build 'BuildCodexAppServerShim.ps1' @{ TargetCodexPath=$codexTarget; OutputDirectory=(Join-Path $stageDir 'shim-build') }
    Invoke-Build 'BuildCodexLocalCompanion.ps1' @{ OutputDirectory=(Join-Path $stageDir 'companion-build') }
    Invoke-Build 'BuildCodexLanGateway.ps1' @{ OutputDirectory=(Join-Path $stageDir 'gateway-build') }
    Invoke-Build 'BuildCodexMobileUiServer.ps1' @{ OutputDirectory=(Join-Path $stageDir 'mobile-build') }
    Invoke-Build 'BuildCodexRemoteTray.ps1' @{ OutputDirectory=(Join-Path $stageDir 'tray-build') }

    Set-Content -LiteralPath (Join-Path $stageDir 'shim-build\CodexAppServerShim.mode') -Value 'local-bridge' -Encoding ASCII
    Copy-Item -LiteralPath (Join-Path $sourceDir 'Select-CodexLiveThread.ps1') -Destination (Join-Path $stageDir 'Select-CodexLiveThread.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $sourceDir 'Uninstall-RemoteApprovals.ps1') -Destination (Join-Path $stageDir 'Uninstall-RemoteApprovals.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $sourceDir 'mobile') -Destination (Join-Path $stageDir 'mobile') -Recurse -Force

    New-Item -ItemType Directory -Path (Split-Path -Parent $installDir) -Force | Out-Null
    if (Test-Path -LiteralPath $installDir) { Remove-Item -LiteralPath $installDir -Recurse -Force }
    Move-Item -LiteralPath $stageDir -Destination $installDir

    $installedShim = Join-Path $installDir 'shim-build\CodexAppServerShim.exe'
    $settingState = Set-InstallerCliSetting $settingsPath $installedShim

    $wsh = New-Object -ComObject WScript.Shell
    $link = $wsh.CreateShortcut($startupShortcut)
    $link.TargetPath = Join-Path $installDir 'tray-build\CodexRemoteTray.exe'
    $link.WorkingDirectory = $installDir
    $link.Description = 'Codex Remote Approvals tray application'
    $link.Save()

    $state = [ordered]@{
        version = 1
        installedAt = [DateTimeOffset]::Now.ToString('o')
        installDir = $installDir
        settingsPath = $settingsPath
        installedShim = $installedShim
        previousCliExecutable = $settingState.previousCliExecutable
        settingAdded = [bool]$settingState.added
        settingMigrated = [bool]$settingState.migrated
        startupShortcut = $startupShortcut
        codexTarget = $codexTarget
    }
    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8

    Start-Process -FilePath (Join-Path $installDir 'tray-build\CodexRemoteTray.exe')

    Write-Host ''
    Write-Host 'Codex Remote Approvals installed.' -ForegroundColor Green
    Write-Host "Install directory: $installDir"
    Write-Host 'The tray app is running and will start automatically when you sign in.'
    Write-Host ''
    Write-Host 'NEXT: Open VS Code. The Codex extension will start through the local bridge automatically.' -ForegroundColor Cyan
    Write-Host 'Then use the tray icon -> Enable Remote Approvals -> scan the QR code.' -ForegroundColor Cyan
}
catch {
    if (Test-Path -LiteralPath $stageDir) { Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue }
    throw
}
