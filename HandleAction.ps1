[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Uri
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')
Initialize-CodexUiAutomation

try {
    $parsed = [Uri]$Uri
    if ($parsed.Scheme -ne $script:CodexNotifierProtocol) {
        throw "Unexpected URI scheme: $($parsed.Scheme)"
    }

    $action = $parsed.Host.ToLowerInvariant()
    $token = $parsed.AbsolutePath.Trim('/')

    if ($token -notmatch '^[a-fA-F0-9]{32}$') {
        throw 'Invalid notification action token.'
    }

    $record = Get-CodexActionRecord -Token $token
    if ($null -eq $record) {
        Write-CodexNotifierLog "Ignored stale or unknown notification action '$action' for token=$token."
        exit 0
    }

    $createdUtc = [datetime]::Parse(
        [string]$record.CreatedUtc,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    )
    if (([datetime]::UtcNow - $createdUtc.ToUniversalTime()).TotalMinutes -gt 30) {
        Remove-CodexActionRecord -Token $token
        Write-CodexNotifierLog "Ignored expired notification action '$action' for token=$token."
        exit 0
    }

    if ([bool]$record.IsTest) {
        Write-CodexNotifierLog "Test native notification action clicked: $action."
        Remove-CodexActionRecord -Token $token
        exit 0
    }

    $processId = [int]$record.ProcessId
    $expectedHandle = [IntPtr]([long]$record.WindowHandle)
    $expectedActions = @($record.ActionNames | ForEach-Object { [string]$_ })

    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if ($null -eq $process -or $process.MainWindowHandle -eq 0) {
        Remove-CodexActionRecord -Token $token
        Write-CodexNotifierLog "Notification action '$action' ignored: VS Code process $processId is no longer available."
        exit 0
    }

    # Fail closed if Windows reused the process/window identity. We only act on the
    # same VS Code window that originally produced the approval notification.
    if ([long]$process.MainWindowHandle -ne $expectedHandle.ToInt64()) {
        Remove-CodexActionRecord -Token $token
        Write-CodexNotifierLog "Notification action '$action' ignored: VS Code window handle changed."
        exit 0
    }

    if ($action -eq 'open') {
        [void](Focus-VSCodeWindow -WindowHandle $expectedHandle)
        Write-CodexNotifierLog "Opened VS Code from native notification for token=$token."
        exit 0
    }

    if ($action -match '^action-(\d+)$') {
        $index = [int]$Matches[1]
        if ($index -lt 0 -or $index -ge $expectedActions.Count) {
            Write-CodexNotifierLog "Ignored out-of-range approval action index $index for token=$token."
            [void](Focus-VSCodeWindow -WindowHandle $expectedHandle)
            exit 0
        }

        $targetName = $expectedActions[$index]
        $ok = Invoke-CodexApprovalAction `
            -WindowHandle $expectedHandle `
            -TargetName $targetName `
            -ExpectedActionNames $expectedActions

        if (-not $ok) {
            [void](Focus-VSCodeWindow -WindowHandle $expectedHandle)
        }
        else {
            Remove-CodexActionRecord -Token $token
        }
        exit 0
    }

    Write-CodexNotifierLog "Ignored unknown native notification action '$action'."
}
catch {
    Write-CodexNotifierLog "Native notification action handler failed for '$Uri': $($_.Exception.Message)"
    exit 1
}
