# Codex Approval Notifier for Windows

## Codex Remote Approvals v4.0.0

**Review and respond to native VS Code Codex command-execution approvals from a paired phone on your trusted local network.**

Codex Remote Approvals preserves Codex's existing human-approval boundary instead of exposing a remote shell, arbitrary commands, or unrestricted Codex app-server RPC.

> **Unofficial open-source project.** This project is not affiliated with or maintained by OpenAI or Microsoft.

**[Watch the guide](#guide) · [Quick start](#quick-start) · [Security model](#security-model) · [v4.0.0 source tag](https://github.com/tobiasGuta/VS-Code-Codex-Approval-Notifier-for-Windows/tree/v4.0.0)**

## Why this exists

Codex can require explicit human approval before performing consequential actions. That works well while the developer is sitting at the workstation, but it becomes inconvenient when the developer briefly steps away.

The obvious remote-access solution would be to expose a shell, arbitrary commands, prompt submission, or the full Codex app-server API over the network. Codex Remote Approvals deliberately does not do that.

Instead, V4 keeps the authorization boundary narrow:

```text
Codex creates a native approval request
                |
                v
V4 observes that existing approval
                |
                v
A paired phone receives a one-time approval handle
                |
                v
The human chooses Allow or Deny
                |
                v
The decision returns to the same live Codex session
```

The phone cannot invent commands, submit arbitrary prompts, or create approvals that Codex did not already request.

## Guide

The following clips show the current V4 workflow in the same order it is performed: installation, startup, pairing, phone connection, and live approval handling.

### 1. Install Codex Remote Approvals

https://github.com/user-attachments/assets/1de3301e-da01-4358-942d-3829839fda48

### 2. Start the installed application and reopen VS Code

https://github.com/user-attachments/assets/415629a3-5dbb-4215-9e21-dd22106ccc6d

### 3. Enable Remote Approvals and open the pairing flow

https://github.com/user-attachments/assets/bff239a5-df24-4503-be61-d4212fae0cbc

### 4. Scan the QR code and connect the phone

https://github.com/user-attachments/assets/ce616652-5e43-4129-a83f-f218380b26fa

### 5. Live Codex approval from a physical phone

https://github.com/user-attachments/assets/30349121-c7a3-4cf6-9d34-7b1171c90f97

The final demonstration shows the computer and phone together so the approval appearing on the phone and the resulting Codex action can be observed in real time.

## Quick start

1. Save your work and close **all** VS Code windows.
2. Run `CodexRemoteApprovals-Setup.exe` as your normal Windows user.
3. Reopen VS Code and keep one Codex chat active.
4. Start **Codex Remote Approvals** from the tray or Startup entry.
5. Open the tray menu and choose **Enable Remote Approvals**.
6. Choose **Pair Phone** and scan the locally generated QR code from a phone on the same trusted LAN.
7. Review pending Codex command approvals on the phone and choose **Allow once** or **Deny**.
8. Choose **Disable Remote Approvals** when remote access is no longer needed.

Administrator rights are not required for the V4 per-user installation.

The accepted V4.0.0 installer candidate was validated with SHA-256:

```text
05338C17345D12D6BEBA58662DE15DB9DED4489CE237D404C9EB32FE1780A6DD
```

The public `v4.0.0` source tag is available at:

https://github.com/tobiasGuta/VS-Code-Codex-Approval-Notifier-for-Windows/tree/v4.0.0

## What V4 can do

- Detect the currently loaded/resumable Codex chat from the live VS Code session.
- Start a supervised local companion, LAN gateway, mobile UI, and tray controller.
- Pair one phone using a short-lived one-time six-digit code or QR flow.
- Show pending native Codex **command execution** approvals on the phone.
- Accept or decline those approvals using one-time opaque approval handles.
- Reject stale, replayed, expired, resolved, or wrong-session handles.
- Automatically decline an approval when its companion-side TTL expires; V4 never auto-accepts.
- Revoke the current paired device.
- Tear the local stack down if a tray-owned component exits unexpectedly.
- Invalidate device/session credentials when the corresponding runtime restarts.
- Protect runtime credential directories from inherited access by `CodexSandboxUsers` and other unexpected Windows identities.

## Engineering highlights

- One live Codex app-server remains owned by the VS Code session.
- A second authenticated local WebSocket client observes the same live session instead of launching a competing Codex writer.
- Short-lived six-digit/QR pairing establishes one paired phone.
- The gateway uses a random 256-bit in-memory device credential.
- One-time approval handles prevent stale/replayed decisions.
- Approval expiry can only result in an automatic decline, never an automatic accept.
- Runtime descriptors validate PID plus process start time to reject stale identity and PID reuse.
- The shim owns the exact Codex child through a Windows Job Object with kill-on-close semantics.
- The tray supervises only the companion, gateway, and mobile processes it owns.
- Sensitive runtime directories use protected Windows ACLs.
- The per-user installer configures the VS Code Codex CLI shim and records enough ownership state for safe rollback.

## V4 architecture

```text
VS Code
  |
  | stdio
  v
CodexAppServerShim.exe
  |
  | loopback authenticated WebSocket
  v
ONE bundled Codex app-server
  |
  | second local WebSocket client
  v
CodexLocalCompanion.exe        127.0.0.1:8765
  |
  | localhost bearer-auth HTTP
  v
CodexLanGateway.exe            explicit RFC1918 address:8766
  |
  | one-time pairing + device token
  v
CodexMobileUiServer.exe        same RFC1918 address:8767
  |
  v
Phone browser
```

The core V4 invariant is:

> **One app-server owns the live VS Code Codex session. Multiple local UIs may observe/control that same process, but V4 never launches a second Codex writer to fake remote access.**

## Security model

**The phone is an approval surface, not a remote execution surface.**

Remote approvals sit on a permission boundary, so conservative behavior is intentional.

V4:

- does **not** change Codex's approval policy;
- does **not** automatically approve requests;
- does **not** expose arbitrary command execution over HTTP;
- does **not** expose arbitrary Codex app-server RPC;
- does **not** support remote file approvals, permission grants, steering, interrupt, or arbitrary prompt submission;
- keeps the Codex app-server listener on loopback only;
- rejects `0.0.0.0` for the LAN gateway;
- permits only an explicit loopback/RFC1918 listener address;
- uses a one-time pairing code and an in-memory device token;
- uses one-time approval handles and rejects stale/replayed decisions;
- preserves Codex's own approval request IDs and thread identity;
- fails closed if more than one resumable Codex chat is active;
- fails closed on stale runtime descriptors or PID reuse;
- supervises only processes it started and never broadly kills unrelated `codex.exe` processes;
- stores sensitive bridge/companion tokens only under hardened per-user runtime directories.

The runtime ACL boundary protects credentials from other Windows identities such as Codex sandbox accounts. It does **not** attempt to protect a user's secrets from arbitrary malicious processes already running as that same Windows user.

## Current network limitation

> [!WARNING]
> **V4.0.0 uses HTTP on the trusted LAN between the phone and the local mobile/gateway service.** Pairing and device-token authentication prevent unauthenticated use, but HTTP does not protect traffic from an attacker who can intercept the local network. Use V4 only on a trusted LAN. Do not expose ports 8766 or 8767 to the public Internet and do not configure port forwarding or UPnP for them.

HTTPS is a possible future improvement; it is not part of V4.0.0.

## Requirements

### To use Codex Remote Approvals

- Windows 11
- Visual Studio Code desktop
- OpenAI Codex VS Code extension
- x64-compatible Windows environment
- Phone and PC on the same trusted LAN for remote approvals

### To build the Setup executable from source

- Windows PowerShell 5.1
- .NET Framework C# compiler available on Windows
- Inno Setup 6

The runtime-security acceptance suite has also been validated from PowerShell 7.

## Installation details

The V4 installed payload is placed under:

```text
%LOCALAPPDATA%\CodexApprovalNotifier\remote
```

Sensitive runtime state is kept separately under:

```text
%LOCALAPPDATA%\CodexApprovalNotifier\local-bridge
%LOCALAPPDATA%\CodexApprovalNotifier\companion
%LOCALAPPDATA%\CodexApprovalNotifier\lan-gateway
```

Those runtime directories are hardened to current-user + `SYSTEM` + `Administrators` FullControl with inheritance from the broader LocalAppData ACL blocked.

The installer configures the Codex CLI shim while VS Code is closed and records installer ownership state so uninstall can restore the previous setting safely.

## Normal V4 usage

After installation:

1. Open VS Code and open the single Codex chat you want to supervise.
2. Start **Codex Remote Approvals** from the tray/Startup entry if it is not already running.
3. Open the tray menu and choose **Enable Remote Approvals**.
4. The tray validates the live Codex bridge and starts the companion, LAN gateway, and mobile UI.
5. Choose **Pair Phone** and scan the locally generated QR code.
6. Use the phone page to review pending command approvals and choose **Allow once** or **Deny**.
7. Use **Disable Remote Approvals** when remote access is no longer needed.

If more than one resumable Codex chat exists, V4 intentionally refuses to guess which one should be remotely controlled. Close the extra Codex chats/windows and enable again.

## Pairing behavior

- Pairing code: six digits.
- Pairing lifetime: five minutes.
- Pairing code: single use.
- Failed attempts: rate-limited per source IP.
- Device credential: random 256-bit token kept in gateway memory.
- Gateway restart: invalidates the old device token and pairing state.
- V4.0.0 supports one paired device at a time.
- QR generation is local; the pairing secret is placed in the URL fragment so it is handled client-side and scrubbed before the pairing POST.

## Approval lifecycle

The local companion is authoritative for approval freshness.

Pending command approvals receive opaque one-time handles. The default approval TTL is five minutes. If an approval expires, the companion removes the phone-decidable handle and sends the exact native **decline** response for that request. A failed decline send is retried rather than converted into an accept.

Completed, resolved, stale, expired, or replayed handles are rejected.

## Runtime lifecycle hardening

V4 includes several reliability/security protections discovered during acceptance testing:

- The shim owns the exact Codex child in a Windows Job Object using kill-on-close semantics.
- A cleanup guardian waits on the exact shim process handle and removes only that shim's descriptor/token artifacts after abnormal termination.
- Bridge descriptors include process identity and creation time and are rejected when the PID belongs to a newer process instance.
- The thread selector and companion launcher preserve sub-second descriptor timestamps so legitimate same-second process startup is not mistaken for PID reuse.
- Companion and gateway restarts invalidate prior credentials/handles.
- The tray supervises only its own companion/gateway/mobile children and tears down the remaining stack if one exits unexpectedly.
- Runtime credential directories block inherited LocalAppData ACLs, removing the previously inherited `CodexSandboxUsers` read path.
- New runtime files inherit only the protected runtime-directory DACL.
- Stale matching runtime artifacts are cleaned up without deleting unrelated files.

## V4 runtime components

```text
CodexAppServerShim.cs / shim-build\CodexAppServerShim.exe
    VS Code CLI shim. Keeps the real Codex app-server loopback-only and publishes
    a local authenticated bridge descriptor/token.

Select-CodexLiveThread.ps1
    Validates the bridge identity and selects exactly one live resumable Codex chat.

CodexLocalCompanion.cs / companion-build\CodexLocalCompanion.exe
    Loopback-only approval lifecycle service. Tracks native command approvals,
    TTLs, one-time handles, resolution, and accept/decline decisions.

CodexLanGateway.cs / gateway-build\CodexLanGateway.exe
    Explicit trusted-LAN listener. Owns pairing/device-token authentication and
    proxies only the narrow status/approval API to the local companion.

CodexMobileUiServer.cs / mobile-build\CodexMobileUiServer.exe
    Serves the phone UI and same-origin gateway proxy. It does not receive the
    Codex app-server or companion bearer token.

CodexRemoteTray.cs / tray-build\CodexRemoteTray.exe
    Windows tray controller for enable/pair/disable/status plus owned-process
    supervision.

Initialize-CodexRuntimeSecurity.ps1
    Applies and verifies runtime credential-directory ACL policy and stale-artifact
    cleanup.

Configure-InstalledRemoteApprovals.ps1
Unconfigure-InstalledRemoteApprovals.ps1
    Installer-owned VS Code shim configuration and safe rollback.

Build-CodexRemoteApprovalsSetup.ps1
installer\CodexRemoteApprovals.iss
    Builds the per-user V4 Setup executable.
```

## Build the V4 Setup executable from source

Install Inno Setup 6, then from the repository root run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Build-CodexRemoteApprovalsSetup.ps1
```

The build script compiles the bundled C# components, creates the installer payload, invokes Inno Setup, and prints the SHA-256 of the resulting Setup executable.

Expected output location:

```text
setup-output\CodexRemoteApprovals-Setup.exe
```

## Uninstall V4

Save your work and close **all** VS Code windows before uninstalling. This is required so the installer can safely restore the previous Codex CLI setting.

Use Windows **Installed apps / Add or Remove Programs** and uninstall **Codex Remote Approvals**.

The uninstaller runs the owned rollback logic before removing the installed payload. It refuses to guess how to restore a VS Code CLI setting it does not own.

## Tested release properties

V4.0.0 was accepted against the intended home-LAN workflow with:

- real VS Code + Codex live bridge startup;
- exact live-thread selection;
- phone QR pairing;
- mobile approval flow;
- real prompt/approval interaction;
- restart/session invalidation;
- approval expiry/automatic decline behavior;
- shim abnormal-exit child cleanup;
- tray-owned stack supervision;
- stale/PID-reuse descriptor rejection;
- same-second timestamp precision regression coverage;
- non-admin runtime ACL initialization;
- PowerShell 5.1 runtime-security acceptance;
- PowerShell 7 runtime-security acceptance;
- idempotent ACL initialization;
- safe inheritance for future runtime files;
- stale credential cleanup;
- clean per-user installation;
- live installed phone approval regression;
- clean uninstall and VS Code setting rollback.

## What is intentionally not in V4.0.0

The following are possible future work, not incomplete V4 requirements:

- HTTPS for LAN traffic;
- persistent multi-device pairing;
- a broader local audit-log experience;
- additional reconnect/concurrency stress testing;
- remote steering, interrupt, arbitrary prompts, arbitrary RPC, or arbitrary shell execution.

The last group is intentionally excluded from the V4 security model rather than merely postponed.

## Legacy local Windows notifier

The original Windows notification implementation remains in the repository:

```text
CodexApprovalNotifier.ps1
Common.ps1
HandleAction.ps1
ActionLauncher.cs
Install.ps1
Uninstall.ps1
Test-Notification.ps1
Diagnose.ps1
```

That workflow watches the VS Code accessibility tree and mirrors the approval buttons into native Windows notifications. It is separate from the V4 phone/LAN architecture and retains its existing limitations, including reduced reliability when the VS Code window is minimized and dependence on Codex/VS Code accessibility labels.

To install the legacy local notifier from source:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Install.ps1
```

## Acknowledgments

V4 development, debugging, test planning, security review, and documentation were assisted by **ChatGPT (OpenAI)**. GitHub contributor attribution remains tied to the human repository authors and commit identities.
