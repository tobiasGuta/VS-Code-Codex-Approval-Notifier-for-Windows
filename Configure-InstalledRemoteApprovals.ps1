[CmdletBinding()]
param(
    [string]$InstallDir = $PSScriptRoot,
    [string]$LogPath = (Join-Path $env:TEMP 'CodexRemoteApprovals-configure.log')
)

$ErrorActionPreference = 'Stop'

function Write-SetupLog([string]$Message) {
    $line = ('[{0}] {1}' -f ([DateTimeOffset]::Now.ToString('o')), $Message)
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Decode-JsonPath([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $slash = [string][char]92
    return $Value.Replace($slash + $slash, $slash)
}

function Encode-JsonPath([string]$Value) {
    $slash = [string][char]92
    return $Value.Replace($slash, $slash + $slash).Replace('"', $slash + '"')
}

function Get-CliExecutableMatch([string]$Text) {
    return [regex]::Match($Text, '(?m)^\s*["'']chatgpt\.cliExecutable["'']\s*:\s*["''](?<v>[^"'']+)["'']\s*,?\s*(?://.*)?$')
}

function Normalize-PathValue([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $decoded = Decode-JsonPath $Value
    try { return [IO.Path]::GetFullPath($decoded) } catch { return $decoded }
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
                [pscustomobject]@{ Path = $codex; Stamp = $_.LastWriteTimeUtc }
            }
        } |
        Sort-Object Stamp -Descending
    )

    if ($candidates.Count -eq 0) {
        throw 'No installed Windows x64 OpenAI Codex extension binary was found.'
    }
    return [string]$candidates[0].Path
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
    }
    catch { return $false }
}

function Set-OwnedCliSetting([string]$SettingsPath, [string]$InstalledShim) {
    $text = if (Test-Path -LiteralPath $SettingsPath -PathType Leaf) {
        [IO.File]::ReadAllText($SettingsPath)
    }
    else {
        "{`r`n}`r`n"
    }

    $match = Get-CliExecutableMatch $text
    $existing = if ($match.Success) { Normalize-PathValue $match.Groups['v'].Value } else { $null }
    $normalizedInstalled = Normalize-PathValue $InstalledShim
    $state = [ordered]@{ previousCliExecutable = $null; settingAdded = $false; settingMigrated = $false }
    $jsonShim = Encode-JsonPath $InstalledShim

    if ([string]::IsNullOrWhiteSpace($existing)) {
        $brace = $text.IndexOf('{')
        if ($brace -lt 0) { throw 'VS Code settings.json does not contain a top-level opening brace.' }
        $insertion = "`r`n    // Codex Remote Approvals`r`n    `"chatgpt.cliExecutable`": `"$jsonShim`"," 
        $text = $text.Insert($brace + 1, $insertion)
        $state.settingAdded = $true
    }
    elseif ([string]::Equals($existing, $normalizedInstalled, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'VS Code already points to this installed shim but installer ownership state is missing. Refusing to guess how to restore the prior setting.'
    }
    elseif (Is-RecognizedPrototypeShim $existing) {
        $state.previousCliExecutable = $existing
        $state.settingMigrated = $true
        $pattern = '(?m)^(?<indent>\s*)["'']chatgpt\.cliExecutable["'']\s*:\s*["''][^"'']+["''](?<tail>\s*,?\s*(?://.*)?)$'
        $text = [regex]::Replace($text, $pattern, '${indent}"chatgpt.cliExecutable": "' + $jsonShim + '"${tail}', 1)
    }
    else {
        throw "VS Code already has a custom chatgpt.cliExecutable setting that Codex Remote Approvals does not own: $existing"
    }

    $parent = Split-Path -Parent $SettingsPath
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    [IO.File]::WriteAllText($SettingsPath, $text, (New-Object Text.UTF8Encoding($false)))
    return $state
}

try {
    Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
    Write-SetupLog 'Starting Codex Remote Approvals installed-payload configuration.'

    if (@(Get-Process -Name Code -ErrorAction SilentlyContinue).Count -gt 0) {
        throw 'Close all VS Code windows before installing Codex Remote Approvals.'
    }

    $InstallDir = [IO.Path]::GetFullPath($InstallDir)
    $shim = Join-Path $InstallDir 'shim-build\CodexAppServerShim.exe'
    $targetFile = Join-Path $InstallDir 'shim-build\CodexAppServerShim.target'
    $modeFile = Join-Path $InstallDir 'shim-build\CodexAppServerShim.mode'
    $statePath = Join-Path $InstallDir 'install-state.json'
    $settingsPath = Join-Path $env:APPDATA 'Code\User\settings.json'

    foreach ($required in @(
        $shim,
        (Join-Path $InstallDir 'companion-build\CodexLocalCompanion.exe'),
        (Join-Path $InstallDir 'gateway-build\CodexLanGateway.exe'),
        (Join-Path $InstallDir 'mobile-build\CodexMobileUiServer.exe'),
        (Join-Path $InstallDir 'tray-build\CodexRemoteTray.exe'),
        (Join-Path $InstallDir 'Select-CodexLiveThread.ps1'),
        (Join-Path $InstallDir 'mobile\index.html'),
        (Join-Path $InstallDir 'mobile\app.js'),
        (Join-Path $InstallDir 'mobile\app.css')
    )) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Installed payload is incomplete: $required"
        }
    }

    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        throw 'Codex Remote Approvals installer state already exists. Uninstall the current copy before reinstalling this prototype.'
    }

    $codexTarget = Find-InstalledCodexBinary
    Write-SetupLog "Detected Codex extension binary: $codexTarget"

    $settingsExisted = Test-Path -LiteralPath $settingsPath -PathType Leaf
    $settingsBefore = if ($settingsExisted) { [IO.File]::ReadAllText($settingsPath) } else { $null }
    $targetExisted = Test-Path -LiteralPath $targetFile -PathType Leaf
    $targetBefore = if ($targetExisted) { [IO.File]::ReadAllText($targetFile) } else { $null }
    $modeExisted = Test-Path -LiteralPath $modeFile -PathType Leaf
    $modeBefore = if ($modeExisted) { [IO.File]::ReadAllText($modeFile) } else { $null }

    try {
        Set-Content -LiteralPath $targetFile -Value $codexTarget -Encoding UTF8
        Set-Content -LiteralPath $modeFile -Value 'local-bridge' -Encoding ASCII
        $settingState = Set-OwnedCliSetting $settingsPath $shim

        $state = [ordered]@{
            version = 1
            installedAt = [DateTimeOffset]::Now.ToString('o')
            installDir = $InstallDir
            settingsPath = $settingsPath
            installedShim = $shim
            previousCliExecutable = $settingState.previousCliExecutable
            settingAdded = [bool]$settingState.settingAdded
            settingMigrated = [bool]$settingState.settingMigrated
            codexTarget = $codexTarget
        }
        $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8
    }
    catch {
        try {
            if ($settingsExisted) {
                [IO.File]::WriteAllText($settingsPath, $settingsBefore, (New-Object Text.UTF8Encoding($false)))
            }
            else {
                Remove-Item -LiteralPath $settingsPath -Force -ErrorAction SilentlyContinue
            }
            if ($targetExisted) { [IO.File]::WriteAllText($targetFile, $targetBefore, (New-Object Text.UTF8Encoding($false))) }
            else { Remove-Item -LiteralPath $targetFile -Force -ErrorAction SilentlyContinue }
            if ($modeExisted) { [IO.File]::WriteAllText($modeFile, $modeBefore, (New-Object Text.UTF8Encoding($false))) }
            else { Remove-Item -LiteralPath $modeFile -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
        }
        catch { }
        throw
    }

    Write-SetupLog 'Configuration completed successfully.'
    exit 0
}
catch {
    try { Write-SetupLog ('FAILED: ' + $_.Exception.Message) } catch { }
    Write-Error $_.Exception.Message
    exit 1
}
