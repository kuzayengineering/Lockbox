; Windows installer for Lockbox (Inno Setup 6).
; Built by .github/workflows/build.yml:  iscc /DAppVersion=1.0.N installer\lockbox.iss
;
; Installs for the current user only (no administrator rights needed) into
; %LOCALAPPDATA%\Programs\Lockbox, with a Start menu shortcut and an
; uninstaller. The vault (Documents\Lockbox Vault by default) is never
; touched by installing, updating or uninstalling.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
; Never change AppId: updates find the existing installation by it.
AppId={{4B92168E-8DFB-4D5D-9CBF-CF25445DED0A}
AppName=Lockbox
AppVersion={#AppVersion}
AppVerName=Lockbox {#AppVersion}
AppPublisher=Lockbox
DefaultDirName={localappdata}\Programs\Lockbox
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\build\installer
OutputBaseFilename=Lockbox-windows-setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\lockbox.exe
UninstallDisplayName=Lockbox
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Updating while Lockbox is open: close it first.
CloseApplications=force
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[InstallDelete]
; Remove files left over from the previous version.
Type: filesandordirs; Name: "{app}\data"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Lockbox"; Filename: "{app}\lockbox.exe"
Name: "{autodesktop}\Lockbox"; Filename: "{app}\lockbox.exe"; Tasks: desktopicon

[Run]
; Also runs after a quiet automatic update, so Lockbox reopens.
Filename: "{app}\lockbox.exe"; Description: "Open Lockbox"; Flags: nowait postinstall

[UninstallDelete]
Type: filesandordirs; Name: "{app}"
