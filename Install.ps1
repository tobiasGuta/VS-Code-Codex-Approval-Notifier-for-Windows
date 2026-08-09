[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$sourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$filesToInstall = @(
    'Common.ps1',
    'CodexApprovalNotifier.ps1',
    'HandleAction.ps1',
    'BuildActionLauncher.ps1',
    'ActionLauncher.cs',
    'Diagnose.ps1',
    'Test-Notification.ps1',
    'Uninstall.ps1',
    'README.md'
)

foreach ($name in $filesToInstall) {
    $path = Join-Path $sourceDir $name
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing required installer file: $name"
    }

    if ($name.EndsWith('.ps1', [StringComparison]::OrdinalIgnoreCase)) {
        $tokens = $null
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $path,
            [ref]$tokens,
            [ref]$parseErrors
        ) | Out-Null

        if ($parseErrors.Count -gt 0) {
            $messages = ($parseErrors | ForEach-Object { $_.Message }) -join '; '
            throw "$name failed PowerShell syntax validation: $messages"
        }
    }
}

# PowerShell 7 uses .NET (Core), where direct Windows Runtime projection has
# compatibility gaps. Native toast APIs are hosted in Windows PowerShell 5.1
# instead, while this installer can still be launched from pwsh 7.
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $windowsPowerShell)) {
    throw "Windows PowerShell 5.1 was not found at: $windowsPowerShell"
}
$notificationHost = [pscustomobject]@{ Source = $windowsPowerShell }

$installDir = Join-Path $env:LOCALAPPDATA 'CodexApprovalNotifier'
$programsDir = [Environment]::GetFolderPath('Programs')
$startupDir = [Environment]::GetFolderPath('Startup')
$identityShortcut = Join-Path $programsDir 'Codex Approval Notifier.lnk'
$startupShortcut = Join-Path $startupDir 'Codex Approval Notifier.lnk'
$appId = 'Local.CodexApprovalNotifier'
$protocol = 'codexapproval'
$stubClsid = [guid]'26195100-efec-4b78-9ffd-2942e578b782'

# Stop the previous watcher so the v3.3 files can replace it and the single-instance
# mutex will belong to the new process.
Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*$installDir*CodexApprovalNotifier.ps1*" } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
Start-Sleep -Milliseconds 350

New-Item -ItemType Directory -Path $installDir -Force | Out-Null
foreach ($name in $filesToInstall) {
    Copy-Item -LiteralPath (Join-Path $sourceDir $name) -Destination (Join-Path $installDir $name) -Force
}
New-Item -ItemType Directory -Path (Join-Path $installDir 'actions') -Force | Out-Null

$watcher = Join-Path $installDir 'CodexApprovalNotifier.ps1'
$handler = Join-Path $installDir 'HandleAction.ps1'
$actionLauncherSource = Join-Path $installDir 'ActionLauncher.cs'
$actionLauncherBuilder = Join-Path $installDir 'BuildActionLauncher.ps1'
$actionLauncher = Join-Path $installDir 'ActionLauncher.exe'

# Build a tiny Windows-subsystem launcher under Windows PowerShell/.NET Framework.
# It has no console of its own and starts HandleAction.ps1 with CreateNoWindow=true,
# preventing Windows Terminal / PowerShell from flashing when a toast button is clicked.
$launcherBuildOutput = @(
    & $windowsPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass `
        -File $actionLauncherBuilder `
        -SourcePath $actionLauncherSource `
        -OutputPath $actionLauncher 2>&1
)
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $actionLauncher)) {
    $details = ($launcherBuildOutput | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    throw "Silent action launcher build failed.`n$details"
}

$watcherArguments = "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watcher`""

# A real desktop toast identity needs a Start-menu shortcut with an AppUserModelID.
# The stub ToastActivatorCLSID makes the desktop identity suitable for persisted
# native notifications while all of our actions use protocol activation.
if ($null -eq ('CodexShortcutInstaller' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

[ComImport]
[Guid("00021401-0000-0000-C000-000000000046")]
internal class ShellLinkClass { }

[ComImport]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
[Guid("000214F9-0000-0000-C000-000000000046")]
internal interface IShellLinkW
{
    [PreserveSig] int GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszFile, int cch, IntPtr pfd, uint fFlags);
    [PreserveSig] int GetIDList(out IntPtr ppidl);
    [PreserveSig] int SetIDList(IntPtr pidl);
    [PreserveSig] int GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszName, int cch);
    [PreserveSig] int SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
    [PreserveSig] int GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszDir, int cch);
    [PreserveSig] int SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
    [PreserveSig] int GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszArgs, int cch);
    [PreserveSig] int SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
    [PreserveSig] int GetHotkey(out short pwHotkey);
    [PreserveSig] int SetHotkey(short wHotkey);
    [PreserveSig] int GetShowCmd(out int piShowCmd);
    [PreserveSig] int SetShowCmd(int iShowCmd);
    [PreserveSig] int GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszIconPath, int cch, out int piIcon);
    [PreserveSig] int SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);
    [PreserveSig] int SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pszPathRel, uint dwReserved);
    [PreserveSig] int Resolve(IntPtr hwnd, uint fFlags);
    [PreserveSig] int SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
}

[StructLayout(LayoutKind.Sequential, Pack = 4)]
internal struct PROPERTYKEY
{
    public Guid fmtid;
    public uint pid;

    public PROPERTYKEY(Guid formatId, uint propertyId)
    {
        fmtid = formatId;
        pid = propertyId;
    }
}

[StructLayout(LayoutKind.Explicit)]
internal struct PROPVARIANT
{
    [FieldOffset(0)] public ushort vt;
    [FieldOffset(2)] public ushort wReserved1;
    [FieldOffset(4)] public ushort wReserved2;
    [FieldOffset(6)] public ushort wReserved3;
    [FieldOffset(8)] public IntPtr pointerValue;
}

[ComImport]
[Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IPropertyStore
{
    [PreserveSig] int GetCount(out uint cProps);
    [PreserveSig] int GetAt(uint iProp, out PROPERTYKEY pkey);
    [PreserveSig] int GetValue(ref PROPERTYKEY key, out PROPVARIANT pv);
    [PreserveSig] int SetValue(ref PROPERTYKEY key, ref PROPVARIANT pv);
    [PreserveSig] int Commit();
}

public static class CodexShortcutInstaller
{
    private const ushort VT_LPWSTR = 31;
    private const ushort VT_CLSID = 72;
    private static readonly Guid AppUserModelFmtId = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");

    [DllImport("ole32.dll")]
    private static extern int PropVariantClear(ref PROPVARIANT pvar);

    private static void Check(int hr)
    {
        if (hr < 0) Marshal.ThrowExceptionForHR(hr);
    }

    private static PROPVARIANT FromString(string value)
    {
        return new PROPVARIANT
        {
            vt = VT_LPWSTR,
            pointerValue = Marshal.StringToCoTaskMemUni(value)
        };
    }

    private static PROPVARIANT FromGuid(Guid value)
    {
        IntPtr p = Marshal.AllocCoTaskMem(16);
        byte[] bytes = value.ToByteArray();
        Marshal.Copy(bytes, 0, p, 16);
        return new PROPVARIANT
        {
            vt = VT_CLSID,
            pointerValue = p
        };
    }

    public static void Create(
        string shortcutPath,
        string targetPath,
        string arguments,
        string workingDirectory,
        string description,
        string iconPath,
        string appUserModelId,
        Guid toastActivatorClsid)
    {
        object shellObject = new ShellLinkClass();
        try
        {
            IShellLinkW link = (IShellLinkW)shellObject;
            Check(link.SetPath(targetPath));
            Check(link.SetArguments(arguments));
            Check(link.SetWorkingDirectory(workingDirectory));
            Check(link.SetDescription(description));
            if (!String.IsNullOrWhiteSpace(iconPath))
            {
                Check(link.SetIconLocation(iconPath, 0));
            }

            IPropertyStore store = (IPropertyStore)shellObject;
            PROPERTYKEY appIdKey = new PROPERTYKEY(AppUserModelFmtId, 5);
            PROPERTYKEY toastClsidKey = new PROPERTYKEY(AppUserModelFmtId, 26);

            PROPVARIANT appIdValue = FromString(appUserModelId);
            try
            {
                Check(store.SetValue(ref appIdKey, ref appIdValue));
            }
            finally
            {
                PropVariantClear(ref appIdValue);
            }

            PROPVARIANT clsidValue = FromGuid(toastActivatorClsid);
            try
            {
                Check(store.SetValue(ref toastClsidKey, ref clsidValue));
            }
            finally
            {
                PropVariantClear(ref clsidValue);
            }

            Check(store.Commit());
            ((IPersistFile)shellObject).Save(shortcutPath, true);
        }
        finally
        {
            if (Marshal.IsComObject(shellObject))
            {
                Marshal.FinalReleaseComObject(shellObject);
            }
        }
    }
}
'@
}

# Prefer VS Code's icon for the notification identity when it is available.
$iconPath = $null
try {
    $iconPath = Get-Process -Name Code -ErrorAction SilentlyContinue |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.Path) } |
        Select-Object -First 1 -ExpandProperty Path
}
catch {}

if ([string]::IsNullOrWhiteSpace($iconPath)) {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\Code.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft VS Code\Code.exe')
    )
    if (${env:ProgramFiles(x86)}) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft VS Code\Code.exe')
    }
    $iconPath = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if ([string]::IsNullOrWhiteSpace($iconPath)) {
    $iconPath = $notificationHost.Source
}

[CodexShortcutInstaller]::Create(
    $identityShortcut,
    $notificationHost.Source,
    $watcherArguments,
    $installDir,
    'Native Windows notifications for Codex approval requests in VS Code',
    $iconPath,
    $appId,
    $stubClsid
)

# Register a per-user protocol handler. Native toast buttons launch these URIs.
# The protocol enters through ActionLauncher.exe, a Windows-subsystem helper with
# no console window. It starts HandleAction.ps1 with CreateNoWindow=true; the
# PowerShell handler still performs all exact-window / exact-action safety checks.
$protocolRoot = "HKCU:\Software\Classes\$protocol"
New-Item -Path $protocolRoot -Force | Out-Null
Set-Item -Path $protocolRoot -Value 'URL:Codex Approval Notifier'
New-ItemProperty -Path $protocolRoot -Name 'URL Protocol' -Value '' -PropertyType String -Force | Out-Null
New-Item -Path "$protocolRoot\shell\open\command" -Force | Out-Null
$protocolCommand = "`"$actionLauncher`" `"%1`""
Set-Item -Path "$protocolRoot\shell\open\command" -Value $protocolCommand

# Startup shortcut: no special AppUserModelID is required here because the Start-menu
# identity shortcut above owns the native toast identity.
$wshShell = New-Object -ComObject WScript.Shell
$startupLink = $wshShell.CreateShortcut($startupShortcut)
$startupLink.TargetPath = $notificationHost.Source
$startupLink.Arguments = $watcherArguments
$startupLink.WorkingDirectory = $installDir
$startupLink.Description = 'Watch VS Code for Codex approval requests'
$startupLink.IconLocation = "$iconPath,0"
$startupLink.Save()

# Give Explorer a moment to observe the newly created Start-menu identity.
Start-Sleep -Milliseconds 900

# Verify the native identity from Windows PowerShell 5.1. Unlike v3.0, this
# preflight is intentionally visible in the installer console so a failure
# includes the real Windows Runtime error instead of only an exit code.
$preflightOutput = @()
$preflightExitCode = 1
for ($attempt = 1; $attempt -le 4; $attempt++) {
    $preflightOutput = @(
        & $notificationHost.Source -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File $watcher -NativePreflight 2>&1
    )
    $preflightExitCode = $LASTEXITCODE
    if ($preflightExitCode -eq 0) {
        break
    }
    if ($attempt -lt 4) {
        Start-Sleep -Milliseconds (500 * $attempt)
    }
}

if ($preflightExitCode -ne 0) {
    $details = ($preflightOutput | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    throw "Native Windows notification preflight failed after 4 attempts.`n$details"
}

$preflightOutput | ForEach-Object { Write-Host $_ }
Start-Process -FilePath $notificationHost.Source -ArgumentList $watcherArguments -WindowStyle Hidden

Write-Host ''
Write-Host 'Codex Approval Notifier v3.3.1 installed.' -ForegroundColor Green
Write-Host "Installed to: $installDir"
Write-Host "Native notification identity: $identityShortcut"
Write-Host "Startup shortcut: $startupShortcut"
Write-Host ''
Write-Host "v3.3.1 keeps native Windows notifications, mirrors Codex's current approval actions, and handles notification clicks without opening a console window." -ForegroundColor Cyan
Write-Host 'Run .\Test-Notification.ps1 to preview the new native design.' -ForegroundColor Cyan
