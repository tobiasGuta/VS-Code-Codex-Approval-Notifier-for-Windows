$script:CodexNotifierAppId = 'Local.CodexApprovalNotifier'
$script:CodexNotifierProtocol = 'codexapproval'
$script:CodexNotifierStubClsid = '26195100-efec-4b78-9ffd-2942e578b782'

function Get-CodexNotifierDir {
    Join-Path $env:LOCALAPPDATA 'CodexApprovalNotifier'
}

function Get-CodexActionDir {
    $dir = Join-Path (Get-CodexNotifierDir) 'actions'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Write-CodexNotifierLog {
    param([Parameter(Mandatory)][string]$Message)

    try {
        $dir = Get-CodexNotifierDir
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $line = '{0:yyyy-MM-dd HH:mm:ss.fff}  {1}' -f (Get-Date), $Message
        Add-Content -LiteralPath (Join-Path $dir 'watcher.log') -Value $line -Encoding UTF8
    }
    catch {
        # Logging must never stop the notifier.
    }
}

function Initialize-CodexUiAutomation {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes

    if ($null -eq ('CodexApprovalNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class CodexApprovalNative
{
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsIconic(IntPtr hWnd);
}
'@
    }
}

function Get-VSCodeWindows {
    Get-Process -Name Code -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } |
        ForEach-Object {
            [pscustomobject]@{
                ProcessId = $_.Id
                Handle    = [IntPtr]$_.MainWindowHandle
                Title     = $_.MainWindowTitle
            }
        }
}

function Get-CodexButtonElements {
    param([Parameter(Mandatory)][IntPtr]$WindowHandle)

    try {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($WindowHandle)
        if ($null -eq $root) { return @() }

        $condition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Button
        )

        $collection = $root.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            $condition
        )

        $result = New-Object System.Collections.Generic.List[object]
        for ($i = 0; $i -lt $collection.Count; $i++) {
            $result.Add($collection.Item($i))
        }
        return $result.ToArray()
    }
    catch {
        Write-CodexNotifierLog "UI Automation read failed for HWND $($WindowHandle): $($_.Exception.Message)"
        return @()
    }
}

function Get-CodexButtonInfo {
    param([Parameter(Mandatory)][IntPtr]$WindowHandle)

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($button in @(Get-CodexButtonElements -WindowHandle $WindowHandle)) {
        try {
            $name = [string]$button.Current.Name
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $result.Add([pscustomobject]@{
                Name    = $name.Trim()
                Element = $button
            })
        }
        catch {
            # The accessibility tree can change while it is being read.
        }
    }
    return $result.ToArray()
}

function Get-CodexButtonNames {
    param([Parameter(Mandatory)][IntPtr]$WindowHandle)
    return @((Get-CodexButtonInfo -WindowHandle $WindowHandle) | ForEach-Object { $_.Name })
}

function Get-CodexDescendantButtonInfo {
    param([Parameter(Mandatory)]$RootElement)

    try {
        $condition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Button
        )
        $collection = $RootElement.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            $condition
        )

        $result = New-Object System.Collections.Generic.List[object]
        for ($i = 0; $i -lt $collection.Count; $i++) {
            $element = $collection.Item($i)
            try {
                $name = [string]$element.Current.Name
                if ([string]::IsNullOrWhiteSpace($name)) { continue }
                $result.Add([pscustomobject]@{
                    Name    = $name.Trim()
                    Element = $element
                })
            }
            catch {}
        }
        return $result.ToArray()
    }
    catch {
        return @()
    }
}

function Test-CodexApprovalActionLabel {
    param([AllowNull()][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }

    # Do not hard-code a particular approval layout. We only identify buttons
    # whose *current VS Code label* has approval semantics, then preserve that
    # exact label in the Windows notification and action record.
    $normalized = $Name.Trim().ToLowerInvariant()
    return ($normalized -match '^(allow\b|approve\b|deny\b|decline\b|reject\b|always\s+allow\b)')
}

function Get-CodexApprovalSnapshot {
    param([Parameter(Mandatory)][IntPtr]$WindowHandle)

    $allButtonInfo = @(Get-CodexButtonInfo -WindowHandle $WindowHandle)
    if ($allButtonInfo.Count -eq 0) {
        return [pscustomobject]@{
            IsApproval  = $false
            ActionNames = @()
            ButtonInfo  = @()
        }
    }

    $anchors = @($allButtonInfo | Where-Object {
        $_.Name.Trim().ToLowerInvariant() -eq 'approval options'
    })
    if ($anchors.Count -eq 0) {
        return [pscustomobject]@{
            IsApproval  = $false
            ActionNames = @()
            ButtonInfo  = @()
        }
    }

    # Prefer the smallest UI Automation ancestor that contains the Codex
    # "Approval options" anchor plus the actual approval buttons. This keeps
    # unrelated Allow/Approve/Deny controls elsewhere in VS Code out of the toast.
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    foreach ($anchor in $anchors) {
        $ancestor = $anchor.Element
        for ($depth = 0; $depth -lt 7; $depth++) {
            try { $ancestor = $walker.GetParent($ancestor) } catch { $ancestor = $null }
            if ($null -eq $ancestor) { break }

            $localInfo = @(Get-CodexDescendantButtonInfo -RootElement $ancestor)
            if ($localInfo.Count -eq 0) { continue }

            $localHasAnchor = @($localInfo | Where-Object {
                $_.Name.Trim().ToLowerInvariant() -eq 'approval options'
            }).Count -gt 0
            if (-not $localHasAnchor) { continue }

            $actionNames = New-Object System.Collections.Generic.List[string]
            $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($item in $localInfo) {
                if (-not (Test-CodexApprovalActionLabel -Name $item.Name)) { continue }
                if ($seen.Add($item.Name)) { $actionNames.Add($item.Name) }
            }

            if ($actionNames.Count -ge 2 -and $actionNames.Count -le 5) {
                return [pscustomobject]@{
                    IsApproval  = $true
                    ActionNames = $actionNames.ToArray()
                    ButtonInfo  = $localInfo
                }
            }
        }
    }

    # Compatibility fallback for Codex/VS Code builds whose accessibility tree
    # does not group the controls under a small common ancestor.
    $fallbackNames = New-Object System.Collections.Generic.List[string]
    $fallbackSeen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $allButtonInfo) {
        if (-not (Test-CodexApprovalActionLabel -Name $item.Name)) { continue }
        if ($fallbackSeen.Add($item.Name)) { $fallbackNames.Add($item.Name) }
    }

    $fallbackOk = ($fallbackNames.Count -ge 2 -and $fallbackNames.Count -le 5)
    return [pscustomobject]@{
        IsApproval  = $fallbackOk
        ActionNames = if ($fallbackOk) { $fallbackNames.ToArray() } else { @() }
        ButtonInfo  = if ($fallbackOk) { $allButtonInfo } else { @() }
    }
}

function Test-CodexApprovalButtons {
    param([string[]]$ButtonNames)

    if (-not $ButtonNames -or $ButtonNames.Count -eq 0) { return $false }
    $hasApprovalOptions = $false
    $actionCount = 0

    foreach ($name in $ButtonNames) {
        if ($name.Trim().ToLowerInvariant() -eq 'approval options') {
            $hasApprovalOptions = $true
        }
        elseif (Test-CodexApprovalActionLabel -Name $name) {
            $actionCount++
        }
    }

    return ($hasApprovalOptions -and $actionCount -ge 2)
}

function Focus-VSCodeWindow {
    param([Parameter(Mandatory)][IntPtr]$WindowHandle)

    try {
        if ([CodexApprovalNative]::IsIconic($WindowHandle)) {
            [void][CodexApprovalNative]::ShowWindowAsync($WindowHandle, 9) # SW_RESTORE
        }
        else {
            [void][CodexApprovalNative]::ShowWindowAsync($WindowHandle, 5) # SW_SHOW
        }
        [void][CodexApprovalNative]::SetForegroundWindow($WindowHandle)
        return $true
    }
    catch {
        Write-CodexNotifierLog "Could not focus HWND $($WindowHandle): $($_.Exception.Message)"
        return $false
    }
}

function Test-CodexActionSetMatches {
    param(
        [string[]]$Expected,
        [string[]]$Current
    )

    if ($null -eq $Expected) { $Expected = @() }
    if ($null -eq $Current) { $Current = @() }
    if ($Expected.Count -ne $Current.Count) { return $false }

    foreach ($name in $Expected) {
        if (@($Current | Where-Object { $_ -ceq $name }).Count -ne 1) {
            return $false
        }
    }
    return $true
}

function Invoke-CodexApprovalAction {
    param(
        [Parameter(Mandatory)][IntPtr]$WindowHandle,
        [Parameter(Mandatory)][string]$TargetName,
        [Parameter(Mandatory)][string[]]$ExpectedActionNames
    )

    try {
        $snapshot = Get-CodexApprovalSnapshot -WindowHandle $WindowHandle
        if (-not $snapshot.IsApproval) {
            Write-CodexNotifierLog "Action '$TargetName' aborted: Codex approval signature changed or cleared for HWND $($WindowHandle)."
            return $false
        }

        if (-not (Test-CodexActionSetMatches -Expected $ExpectedActionNames -Current $snapshot.ActionNames)) {
            Write-CodexNotifierLog "Action '$TargetName' aborted: available approval choices changed for HWND $($WindowHandle)."
            return $false
        }

        if (@($ExpectedActionNames | Where-Object { $_ -ceq $TargetName }).Count -ne 1) {
            Write-CodexNotifierLog "Action '$TargetName' aborted: target was not in the recorded approval choices."
            return $false
        }

        $matches = @($snapshot.ButtonInfo | Where-Object { $_.Name -ceq $TargetName })

        # Never guess which control to invoke. There must be exactly one exact match.
        if ($matches.Count -ne 1) {
            Write-CodexNotifierLog "Action '$TargetName' aborted: expected one exact matching button, found $($matches.Count)."
            return $false
        }

        $pattern = $matches[0].Element.GetCurrentPattern(
            [System.Windows.Automation.InvokePattern]::Pattern
        )
        if ($null -eq $pattern) {
            Write-CodexNotifierLog "Action '$TargetName' aborted: control does not expose InvokePattern."
            return $false
        }

        ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
        Write-CodexNotifierLog "Notification action '$TargetName' invoked for HWND $($WindowHandle)."
        return $true
    }
    catch {
        Write-CodexNotifierLog "Action '$TargetName' failed for HWND $($WindowHandle): $($_.Exception.Message)"
        return $false
    }
}

function New-CodexActionRecord {
    param(
        [int]$ProcessId,
        [IntPtr]$WindowHandle,
        [string]$WindowTitle,
        [string[]]$ActionNames,
        [switch]$IsTest
    )

    $token = [guid]::NewGuid().ToString('N')
    $record = [pscustomobject]@{
        Version      = 2
        Token        = $token
        ProcessId    = $ProcessId
        WindowHandle = $WindowHandle.ToInt64()
        WindowTitle  = $WindowTitle
        ActionNames  = @($ActionNames)
        CreatedUtc   = [DateTime]::UtcNow.ToString('o')
        IsTest       = [bool]$IsTest
    }

    $path = Join-Path (Get-CodexActionDir) "$token.json"
    $record | ConvertTo-Json -Compress | Set-Content -LiteralPath $path -Encoding UTF8
    return $record
}

function Get-CodexActionRecord {
    param([Parameter(Mandatory)][string]$Token)

    if ($Token -notmatch '^[a-fA-F0-9]{32}$') {
        return $null
    }

    $path = Join-Path (Get-CodexActionDir) "$Token.json"
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    catch {
        Write-CodexNotifierLog "Could not read action record '$Token': $($_.Exception.Message)"
        return $null
    }
}

function Remove-CodexActionRecord {
    param([string]$Token)

    if ([string]::IsNullOrWhiteSpace($Token)) { return }
    if ($Token -notmatch '^[a-fA-F0-9]{32}$') { return }

    $path = Join-Path (Get-CodexActionDir) "$Token.json"
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
}

function Remove-ExpiredCodexActionRecords {
    param([int]$MaxAgeMinutes = 60)

    try {
        $cutoff = (Get-Date).AddMinutes(-1 * $MaxAgeMinutes)
        Get-ChildItem -LiteralPath (Get-CodexActionDir) -Filter '*.json' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    catch {
        # Best-effort cleanup only.
    }
}
