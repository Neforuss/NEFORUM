; NEFORUM for Windows: installer script for Inno Setup 6.
;
;   flutter build windows --release
;   iscc installer\neforum.iss            (from apps/neforum_app)
;
; Output: build\installer\NEFORUM-Setup-<version>.exe
;
; Installs per user by default (no administrator prompt); the user can pick
; "install for all users" instead. Settings, accounts and posts live in the
; user's app data folder and are kept on uninstall.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#define AppName "NEFORUM"
#define AppExe "NEFORUM.exe"
#define BuildDir "..\build\windows\x64\runner\Release"

[Setup]
AppId={{B6B0E4E2-2F7C-4C8B-9B57-8E1F2D7A4C31}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=NEFORUM contributors
AppPublisherURL=https://github.com/neforum-app/neforum
AppSupportURL=https://github.com/neforum-app/neforum/issues
AppComments=One app, one message, every platform. Free and open source (GPL-3.0).
VersionInfoVersion={#AppVersion}
VersionInfoProductName={#AppName}
VersionInfoDescription={#AppName} setup
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir=..\build\installer
OutputBaseFilename=NEFORUM-Setup-{#AppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
LicenseFile=..\..\..\LICENSE
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
; NEFORUM keeps running in the tray; make sure it is closed before files are
; replaced or removed. Matches the single-instance mutex in runner/main.cpp.
AppMutex=Local\org.neforum.NEFORUM
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
; The AppUserModelID must match the one notifications use (lib/platform/notifications.dart).
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"; AppUserModelID: "org.neforum.NEFORUM"; Comment: "One app, one message, every platform"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon; AppUserModelID: "org.neforum.NEFORUM"

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Stop a copy still running in the tray so its files can be removed.
Filename: "{sys}\taskkill.exe"; Parameters: "/IM {#AppExe} /F"; Flags: runhidden; RunOnceId: "StopNeforum"

[Registry]
; "Start NEFORUM when I sign in" writes this value; remove it with the app.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "{#AppName}"; Flags: uninsdeletevalue dontcreatekey
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "org.neforum.NEFORUM"; Flags: uninsdeletevalue dontcreatekey
