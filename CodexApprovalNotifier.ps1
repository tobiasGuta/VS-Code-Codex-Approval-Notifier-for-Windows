[CmdletBinding()]
param(
    [ValidateRange(250, 10000)]
    [int]$PollMilliseconds = 1200,

    [ValidateRange(0, 60)]
    [int]$RenotifyMinutes = 5,

    [switch]$NoSound,
    [switch]$Diagnose,
    [switch]$TestNotification,
    [switch]$NativePreflight
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

function Initialize-CodexNativeNotifications {
    # These are Windows Runtime types built into Windows. No PowerShell module or
    # third-party notification package is required.
    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $null = [Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]
}

function ConvertTo-ToastXmlText {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    return [System.Security.SecurityElement]::Escape($Text)
}

function Show-CodexNativeToast {
    param(
        [int]$ProcessId,
        [IntPtr]$WindowHandle,
        [string]$WindowTitle,
        [string[]]$ActionNames,
        [switch]$IsTest
    )

    Initialize-CodexNativeNotifications

    if ($IsTest) {
        $ActionNames = @('Allow once', 'Deny')
    }
    elseif ($null -eq $ActionNames -or $ActionNames.Count -lt 1) {
        throw 'No approval actions were supplied for the real notification.'
    }

    # Windows ToastGeneric supports up to five action buttons. Codex approval
    # prompts normally expose fewer than that; if more ever appear, keep the
    # first five exactly as VS Code exposed them and log the truncation.
    if ($ActionNames.Count -gt 5) {
        Write-CodexNotifierLog "Approval exposed $($ActionNames.Count) actions; Windows toast will show the first 5."
        $ActionNames = @($ActionNames | Select-Object -First 5)
    }

    $recordParams = @{
        ProcessId    = $ProcessId
        WindowHandle = $WindowHandle
        WindowTitle  = $WindowTitle
        ActionNames  = $ActionNames
        IsTest       = [bool]$IsTest
    }
    $record = New-CodexActionRecord @recordParams

    $token = $record.Token
    $scheme = $script:CodexNotifierProtocol
    $openUri = if ($IsTest) { "${scheme}://test-open/$token" } else { "${scheme}://open/$token" }

    if ($IsTest) {
        $titleText = 'Command approval'
        $bodyText = 'Native Windows notification test. Real notifications mirror the approval choices currently shown by Codex in VS Code.'
    }
    else {
        $titleText = 'Command approval'
        if ([string]::IsNullOrWhiteSpace($WindowTitle)) {
            $bodyText = 'Codex in VS Code is waiting for your approval.'
        }
        else {
            $displayTitle = $WindowTitle
            if ($displayTitle.Length -gt 150) {
                $displayTitle = $displayTitle.Substring(0, 147) + '...'
            }
            $bodyText = "Codex in VS Code is waiting for your approval in $displayTitle"
        }
    }

    $titleXml = ConvertTo-ToastXmlText $titleText
    $bodyXml = ConvertTo-ToastXmlText $bodyText
    $openXml = ConvertTo-ToastXmlText $openUri

    $actionXml = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $ActionNames.Count; $i++) {
        $label = [string]$ActionNames[$i]
        $actionUri = if ($IsTest) {
            "${scheme}://test-action-$i/$token"
        }
        else {
            "${scheme}://action-$i/$token"
        }
        $labelXml = ConvertTo-ToastXmlText $label
        $uriXml = ConvertTo-ToastXmlText $actionUri
        [void]$actionXml.AppendLine(('    <action content="{0}" activationType="protocol" arguments="{1}"/>' -f $labelXml, $uriXml))
    }

    $audioXml = if ($NoSound) { '<audio silent="true"/>' } else { '' }

    # Windows itself renders this ToastGeneric payload, so the banner follows the
    # user's Windows 11 theme, rounded corners, spacing, animation and button style.
    $toastXmlText = @"
<toast activationType="protocol" launch="$openXml">
  <visual>
    <binding template="ToastGeneric">
      <text>$titleXml</text>
      <text>$bodyXml</text>
    </binding>
  </visual>
  <actions>
$($actionXml.ToString().TrimEnd())
  </actions>
  $audioXml
</toast>
"@

    try {
        $xml = [Windows.Data.Xml.Dom.XmlDocument]::new()
        $xml.LoadXml($toastXmlText)

        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        $toast.ExpirationTime = [DateTimeOffset]::Now.AddMinutes(15)

        try {
            $toast.Tag = $token.Substring(0, 16)
            $toast.Group = 'codexapproval'
        }
        catch {
            # Older builds can ignore tag/group without affecting the banner.
        }

        $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($script:CodexNotifierAppId)
        $notifier.Show($toast)
        Write-CodexNotifierLog "Native Windows toast shown. Test=$([bool]$IsTest), token=$token, actions=$($ActionNames -join ' | ')."
        return $token
    }
    catch {
        Remove-CodexActionRecord -Token $token
        throw "Could not show the native Windows notification. Run Install.ps1 first, then retry. $($_.Exception.Message)"
    }
}

function Show-CodexDiagnostics {
    Initialize-CodexUiAutomation

    $windows = @(Get-VSCodeWindows)
    if ($windows.Count -eq 0) {
        Write-Host 'No visible VS Code windows were found.'
        return
    }

    foreach ($window in $windows) {
        Write-Host "`n## VS Code PID $($window.ProcessId): $($window.Title)"
        Write-Host ''
        $names = @(Get-CodexButtonNames -WindowHandle $window.Handle)
        if ($names.Count -eq 0) {
            Write-Host 'No accessible buttons were found.'
            continue
        }

        $names | Sort-Object -Unique | ForEach-Object { Write-Host $_ }
        $snapshot = Get-CodexApprovalSnapshot -WindowHandle $window.Handle
        Write-Host "`nApproval pattern detected: $($snapshot.IsApproval)"
        if ($snapshot.IsApproval) {
            Write-Host "Approval actions mirrored to notification: $($snapshot.ActionNames -join ' | ')"
        }
    }
}

# Native Windows Runtime projection is most reliable from Windows PowerShell 5.1.
# Install.ps1 and Test-Notification.ps1 deliberately launch this script there.
if ($NativePreflight) {
    try {
        Initialize-CodexNativeNotifications
        $null = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($script:CodexNotifierAppId)
        Write-Host 'Native Windows notification API is available.'
        exit 0
    }
    catch {
        Write-Error "Native notification registration is not ready: $($_.Exception.Message)"
        exit 2
    }
}

if ($TestNotification) {
    try {
        $testToastParams = @{
            ProcessId    = 0
            WindowHandle = [IntPtr]::Zero
            WindowTitle  = 'Native notification test'
            IsTest       = $true
        }
        $token = Show-CodexNativeToast @testToastParams
        Write-Host "Native Windows test notification sent. Token: $token"
        exit 0
    }
    catch {
        Write-Error $_.Exception.Message
        exit 3
    }
}

Initialize-CodexUiAutomation

if ($Diagnose) {
    Show-CodexDiagnostics
    exit 0
}

$mutex = New-Object System.Threading.Mutex($false, 'Local\CodexApprovalNotifier')
$hasMutex = $false
$state = @{}

try {
    $hasMutex = $mutex.WaitOne(0, $false)
    if (-not $hasMutex) {
        Write-Host 'Codex Approval Notifier is already running.'
        exit 0
    }

    Remove-ExpiredCodexActionRecords
    Write-CodexNotifierLog 'Watcher started (v3.3 silent native-actions build).'

    while ($true) {
        $now = Get-Date
        $windows = @(Get-VSCodeWindows)
        $seenKeys = New-Object System.Collections.Generic.HashSet[string]

        foreach ($window in $windows) {
            $key = "$($window.ProcessId):$($window.Handle.ToInt64())"
            [void]$seenKeys.Add($key)

            if (-not $state.ContainsKey($key)) {
                $state[$key] = [pscustomobject]@{
                    Active         = $false
                    MissingPolls   = 0
                    LastNotifiedAt = [datetime]::MinValue
                    Token          = $null
                }
            }

            $entry = $state[$key]
            $approvalSnapshot = Get-CodexApprovalSnapshot -WindowHandle $window.Handle

            if ($approvalSnapshot.IsApproval) {
                $entry.MissingPolls = 0
                $shouldNotify = -not $entry.Active

                if (-not $shouldNotify -and $RenotifyMinutes -gt 0) {
                    $shouldNotify = (($now - $entry.LastNotifiedAt).TotalMinutes -ge $RenotifyMinutes)
                }

                if ($shouldNotify) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$entry.Token)) {
                        Remove-CodexActionRecord -Token $entry.Token
                    }

                    $toastParams = @{
                        ProcessId    = $window.ProcessId
                        WindowHandle = $window.Handle
                        WindowTitle  = $window.Title
                        ActionNames  = @($approvalSnapshot.ActionNames)
                    }
                    $entry.Token = Show-CodexNativeToast @toastParams
                    $entry.LastNotifiedAt = $now
                    Write-CodexNotifierLog "Approval detected in PID $($window.ProcessId): $($window.Title); actions=$($approvalSnapshot.ActionNames -join ' | ')"
                }

                $entry.Active = $true
            }
            else {
                if ($entry.Active) {
                    # Require two consecutive misses so a transient accessibility-tree
                    # refresh does not reset the state and create duplicate alerts.
                    $entry.MissingPolls++
                    if ($entry.MissingPolls -ge 2) {
                        $entry.Active = $false
                        $entry.MissingPolls = 0
                        if (-not [string]::IsNullOrWhiteSpace([string]$entry.Token)) {
                            Remove-CodexActionRecord -Token $entry.Token
                            $entry.Token = $null
                        }
                        Write-CodexNotifierLog "Approval cleared in PID $($window.ProcessId)."
                    }
                }
            }
        }

        foreach ($existingKey in @($state.Keys)) {
            if (-not $seenKeys.Contains($existingKey)) {
                $entry = $state[$existingKey]
                if (-not [string]::IsNullOrWhiteSpace([string]$entry.Token)) {
                    Remove-CodexActionRecord -Token $entry.Token
                }
                $state.Remove($existingKey)
            }
        }

        Start-Sleep -Milliseconds $PollMilliseconds
    }
}
catch {
    Write-CodexNotifierLog "Fatal error: $($_.Exception.ToString())"
    throw
}
finally {
    foreach ($entry in @($state.Values)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$entry.Token)) {
            Remove-CodexActionRecord -Token $entry.Token
        }
    }

    if ($hasMutex) {
        try { $mutex.ReleaseMutex() } catch {}
    }
    if ($null -ne $mutex) {
        $mutex.Dispose()
    }
}
