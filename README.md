# Codex Approval Notifier for Windows

Native Windows notifications for **Codex approval requests in the VS Code extension**.

When Codex pauses and waits for permission in VS Code, this utility detects the approval UI and sends a Windows 11 notification. The notification mirrors the approval actions that Codex is currently showing, so you can respond without constantly watching the Codex sidebar.

> **Unofficial project.** This utility is not affiliated with or maintained by OpenAI or Microsoft.

## Why this exists

Codex can pause during a task and wait for an approval such as:

```text
Deny | Allow once
```

If you are working in another application, it is easy to miss that Codex is waiting. Codex Approval Notifier watches the VS Code accessibility tree and turns that state into a native Windows notification.

## Features

- Native Windows 11 notifications — Windows renders the notification, not a custom popup.
- Mirrors the approval actions currently exposed by Codex in VS Code.
- Does **not** change your Codex approval policy or disable “Ask for approval.”
- Clicking an approval action re-validates the current Codex prompt before invoking anything.
- Clicking the notification itself opens/focuses the matching VS Code window.
- Silent action handling — notification buttons do not flash a PowerShell or terminal window.
- Starts automatically when you sign in to Windows.
- Supports multiple VS Code windows.
- Re-notifies for an approval that remains unanswered for 5 minutes by default.
- Includes diagnostic and notification-test scripts.
- No administrator rights required.
- No third-party notification module required.
- The notifier itself makes no network requests.

## Current version

**v3.3.1**

This version uses native Windows notifications, dynamically mirrors Codex approval actions, and uses a small locally built Windows launcher so notification actions run without opening a visible console window.

## Requirements

- Windows 11
- Visual Studio Code desktop
- Codex VS Code extension
- Windows PowerShell 5.1, included with Windows
- Windows accessibility/UI Automation enabled normally

PowerShell 7 can be used to launch the installer, but native notification work is hosted through Windows PowerShell 5.1 because of Windows Runtime compatibility.

## Installation

Download or clone the repository, open PowerShell in the project directory, and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Install.ps1
```

The installer places the runtime files in:

```text
%LOCALAPPDATA%\CodexApprovalNotifier
```

It also creates:

- a Start-menu shortcut used as the Windows notification identity;
- a Startup shortcut so the watcher starts when you sign in;
- a per-user `codexapproval:` protocol handler for notification actions;
- `ActionLauncher.exe`, compiled locally from the included `ActionLauncher.cs` source.

The launcher exists only to start the action handler invisibly so clicking a notification button does not flash a console window.

## Test the notification

After installation:

```powershell
.\Test-Notification.ps1
```

This sends a native Windows test notification. The test uses sample `Allow once` and `Deny` buttons only to preview the UI.

**Real approval notifications do not hard-code those choices.** They mirror the actions currently exposed by Codex in VS Code.

## Normal usage

There is nothing to run manually after installation.

1. Start VS Code normally.
2. Use Codex normally.
3. When Codex displays an approval request, the watcher detects it.
4. Windows displays a native `Command approval` notification.
5. Choose one of the actions shown by Codex, or click the notification to return to VS Code.

For example, if Codex currently exposes:

```text
Deny | Allow once
```

the Windows notification exposes those same actions.

The project does not invent an `Approve for session` option or any other permission level that Codex is not currently showing.

## Safety behavior

Notification actions are intentionally fail-closed.

Before an action is invoked, the handler checks that:

- the original VS Code process still exists;
- the original window handle still matches;
- a Codex approval is still present;
- the current approval-action set still matches the set captured when the notification was created;
- the selected action exists exactly once.

If those checks fail, the notifier does not approve or deny anything. It can instead bring VS Code forward so the request can be reviewed manually.

The notifier never automatically approves a request just because one appears.

## Diagnostics

If an approval is visible in VS Code but no notification appears, leave the approval open and run:

```powershell
.\Diagnose.ps1
```

A working detection should look similar to:

```text
Approval pattern detected: True
Approval actions mirrored to notification: Deny | Allow once
```

The diagnostic output is useful when a VS Code or Codex update changes the accessibility tree.

## Logs

Runtime logs are written locally to:

```text
%LOCALAPPDATA%\CodexApprovalNotifier\watcher.log
```

Temporary notification-action records are kept under:

```text
%LOCALAPPDATA%\CodexApprovalNotifier\actions
```

These records allow a notification click to be matched back to the VS Code window and approval state that originally produced it. Expired/stale actions are ignored.

## Uninstall

Run:

```powershell
.\Uninstall.ps1
```

The uninstaller stops the watcher and removes the installed runtime directory, Startup shortcut, notification identity shortcut, and per-user `codexapproval:` protocol registration.

## Current limitations

### 1. Minimized VS Code windows

This is the main known limitation right now.

When a VS Code window is **minimized**, the Codex/Electron accessibility subtree may stop exposing the approval controls to Windows UI Automation. The watcher can still see the VS Code process/window, but it may no longer see entries such as:

```text
Approval options
Allow once
Deny
```

As a result, an approval that appears while VS Code is minimized may **not generate a notification until VS Code is restored**.

This has been reproduced during testing. The project intentionally does not auto-restore minimized VS Code windows just to make the detector work.

### 2. Depends on the Codex/VS Code accessibility tree

Detection currently relies on Windows UI Automation and the accessible controls exposed by VS Code/Codex. A future Codex or VS Code UI change can rename, regroup, or stop exposing these controls and temporarily break detection.

`Diagnose.ps1` is included specifically to help identify this kind of compatibility break.

### 3. Approval-action recognition is label based

The notifier requires an `Approval options` accessibility anchor and looks for approval-style action labels such as `Allow`, `Approve`, `Deny`, `Decline`, `Reject`, or `Always allow`.

The exact labels are preserved in the notification, but a completely new wording introduced by a future Codex version may need to be added to the recognizer.

### 4. The notification body is intentionally generic

The current version tells you that Codex is waiting for approval and includes the VS Code window title. It does **not yet reliably copy the full human-readable approval question/command into the Windows notification**.

The actionable choices are the important part that is mirrored today.

### 5. Polling, not an official Codex event API

The watcher currently checks VS Code roughly every **1.2 seconds** using UI Automation. It is not subscribed to an official Codex approval event or hook.

Because of that, visibility and accessibility-tree behavior affect detection.

### 6. Windows only

This implementation uses Windows UI Automation, Windows Runtime toast APIs, Start-menu notification identity registration, and a Windows protocol handler. macOS and Linux are not supported by this version.

### 7. Windows notification settings still apply

Focus/Do Not Disturb settings, disabled notifications, or other Windows notification policies can affect whether or how the toast is displayed.

### 8. Stale notifications intentionally stop working

A notification is tied to the approval state that existed when it was created. If Codex moves on, VS Code restarts, the window changes, or the approval options change, an old notification action is rejected rather than acting on a different request.

This is intentional safety behavior, not a bug.

## How it works

```text
Codex approval appears in VS Code
             |
             v
Windows UI Automation reads Codex controls
             |
             v
Approval options + current actions detected
             |
             v
Native Windows toast is created
             |
      +------+------+
      |             |
      v             v
 click action    click toast
      |             |
      v             v
silent action    focus VS Code
launcher
      |
      v
re-check same VS Code window + approval state
      |
      v
invoke the matching Codex UI action
```

## Project files

```text
ActionLauncher.cs             Small no-console launcher for notification actions
BuildActionLauncher.ps1       Builds ActionLauncher.exe locally
CodexApprovalNotifier.ps1     Main watcher and native notification logic
Common.ps1                    UI Automation, action validation, and shared helpers
Diagnose.ps1                  Prints accessible VS Code controls and detection state
HandleAction.ps1              Handles clicks from native Windows notifications
Install.ps1                   Installs/registers/starts the notifier
Test-Notification.ps1         Sends a native test notification
Uninstall.ps1                 Removes the notifier and its user-level registrations
README.md                     Project documentation
```

## Security notes

This tool interacts with an approval boundary, so conservative behavior is intentional.

- It does not disable Codex approval prompts.
- It does not change your Codex permission configuration.
- It does not automatically choose an approval action.
- It rechecks the approval immediately before invoking a button.
- Notification actions are tied to the originating VS Code process/window.
- Unknown, expired, or stale actions are ignored.
- `ActionLauncher.exe` is built on the local machine from source during installation.

You should still read approval requests before allowing commands you do not understand or trust.

## Status

The current implementation is working for the intended everyday workflow: **VS Code open/not minimized, Codex waiting for approval, native Windows notification, and approval response directly from the notification**.

The minimized-window behavior documented above is accepted as a known limitation for now.
