#define MyAppName "Winoid"
#ifndef MyAppVersion
  #define MyAppVersion "0.1.37"
#endif
#define MyAppPublisher "Sergey35853"
#define MyAppURL "https://github.com/Sergey35853/winoid"
#define MyAppExeName "Winoid.cmd"

[Setup]
AppId={{7B255843-360F-4186-9FF3-5EC09BCE31F6}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={autopf}\Winoid
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
LicenseFile=..\LICENSE
OutputDir=..\dist
OutputBaseFilename=Winoid-Setup-{#MyAppVersion}
SetupIconFile=..\assets\android.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\assets\android.ico
MinVersion=10.0.19041

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"
Name: "downloadadb"; Description: "Download Android platform-tools (adb)"; GroupDescription: "Components:"; Flags: checkedonce
Name: "setupbackend"; Description: "Open Android backend setup after installation (experimental)"; GroupDescription: "Components:"; Flags: unchecked
Name: "installps"; Description: "Install PowerShell 7 with winget if missing"; GroupDescription: "Components:"; Flags: unchecked

[Files]
Source: "..\Winoid.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Winoid.cmd"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Winoid.vbs"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\WinoidLauncher.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Setup-Backend.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\config.example.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\assets\android.ico"; DestDir: "{app}\assets"; Flags: ignoreversion
Source: "..\assets\winoid-icon.dex"; DestDir: "{app}\assets"; Flags: ignoreversion
Source: "..\assets\iconjob.ps1"; DestDir: "{app}\assets"; Flags: ignoreversion
Source: "..\docs\screenshot-manager.png"; DestDir: "{app}\docs"; Flags: ignoreversion
Source: "Setup-ADB.ps1"; DestDir: "{app}\installer"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\WinoidLauncher.exe"; WorkingDir: "{app}"; IconFilename: "{app}\assets\android.ico"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\WinoidLauncher.exe"; WorkingDir: "{app}"; IconFilename: "{app}\assets\android.ico"; Tasks: desktopicon

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\installer\Setup-ADB.ps1"""; StatusMsg: "Downloading Android platform-tools..."; Flags: runhidden waituntilterminated; Tasks: downloadadb
Filename: "pwsh.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Setup-Backend.ps1"""; WorkingDir: "{app}"; Description: "Set up Android backend"; Flags: postinstall nowait skipifsilent; Tasks: setupbackend
Filename: "winget.exe"; Parameters: "install --id Microsoft.PowerShell -e --accept-source-agreements --accept-package-agreements"; StatusMsg: "Installing PowerShell 7..."; Flags: runhidden waituntilterminated; Tasks: installps
Filename: "{app}\WinoidLauncher.exe"; WorkingDir: "{app}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent

[Code]
function InitializeSetup(): Boolean;
var
  ResultCode: Integer;
begin
  Result := True;
  if not Exec('pwsh.exe', '-NoProfile -Command "exit 0"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    if MsgBox('PowerShell 7 was not found.' + #13#10 + #13#10 +
              'Winoid needs PowerShell 7. Install it from https://aka.ms/powershell, then run Winoid again.' + #13#10 + #13#10 +
              'Continue the installation anyway?', mbConfirmation, MB_YESNO) = IDNO then
      Result := False;
  end;
end;
