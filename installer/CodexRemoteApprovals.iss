#define MyAppName "Codex Remote Approvals"
#define MyAppVersion "4.0.0"
#define MyAppPublisher "Codex Remote Approvals"
#define MyAppExeName "tray-build\CodexRemoteTray.exe"

[Setup]
AppId={{B2D2552D-5E82-4B7B-A9A6-2EB10A28644D}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\CodexApprovalNotifier\remote
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\setup-output
OutputBaseFilename=CodexRemoteApprovals-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}
CloseApplications=no
RestartApplications=no
SetupLogging=yes
UsePreviousAppDir=no

[Files]
Source: "..\setup-payload\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\Codex Remote Approvals"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"
Name: "{userstartup}\Codex Remote Approvals"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Start Codex Remote Approvals"; Flags: nowait postinstall skipifsilent

[Code]
var
  ConfigurationExitCode: Integer;
  RollbackCompleted: Boolean;

function IsVsCodeRunning(): Boolean;
var
  ResultCode: Integer;
begin
  Result := False;
  if Exec(ExpandConstant('{cmd}'), '/C tasklist /FI "IMAGENAME eq Code.exe" /NH | find /I "Code.exe" >NUL', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    Result := ResultCode = 0;
end;

function InitializeSetup(): Boolean;
begin
  Result := True;
  if IsVsCodeRunning() then
  begin
    MsgBox('Close all Visual Studio Code windows before installing Codex Remote Approvals, then run Setup again.' + #13#10 + #13#10 +
      'Setup will not close VS Code or discard your work.', mbError, MB_OK);
    Result := False;
  end;
end;

function InitializeUninstall(): Boolean;
begin
  Result := True;
  RollbackCompleted := False;
  if IsVsCodeRunning() then
  begin
    MsgBox('Close all Visual Studio Code windows before uninstalling Codex Remote Approvals, then try again.' + #13#10 + #13#10 +
      'This is required so the Codex CLI setting can be restored safely.', mbError, MB_OK);
    Result := False;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  PowerShellPath: String;
  Params: String;
begin
  if CurStep = ssPostInstall then
  begin
    PowerShellPath := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
    Params := '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\Configure-InstalledRemoteApprovals.ps1') + '" -InstallDir "' + ExpandConstant('{app}') + '"';
    if (not Exec(PowerShellPath, Params, ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, ConfigurationExitCode)) or (ConfigurationExitCode <> 0) then
    begin
      MsgBox('Codex Remote Approvals could not be connected to VS Code.' + #13#10 + #13#10 +
        'The installer will stop. Review the Setup log and CodexRemoteApprovals-configure.log in your TEMP folder.', mbError, MB_OK);
      RaiseException('Codex Remote Approvals configuration failed.');
    end;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  PowerShellPath: String;
  Params: String;
  ExitCode: Integer;
begin
  if (CurUninstallStep = usUninstall) and (not RollbackCompleted) then
  begin
    PowerShellPath := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
    Params := '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\Unconfigure-InstalledRemoteApprovals.ps1') + '" -InstallDir "' + ExpandConstant('{app}') + '"';
    if (not Exec(PowerShellPath, Params, ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, ExitCode)) or (ExitCode <> 0) then
    begin
      MsgBox('Codex Remote Approvals could not safely restore the VS Code Codex CLI setting.' + #13#10 + #13#10 +
        'Uninstall has been stopped. Review CodexRemoteApprovals-unconfigure.log in your TEMP folder.', mbError, MB_OK);
      RaiseException('Codex Remote Approvals rollback failed.');
    end;
    RollbackCompleted := True;
  end;
end;
