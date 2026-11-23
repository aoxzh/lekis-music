; Per-user Windows installer for the Flutter desktop build.
;
; release.yml compiles it after `flutter build windows --release`:
;   ISCC.exe /DVersion=0.2.2 /DLekisPayloadDir=<Release dir> /DLekisOutDir=<dist dir> tools\lekis-installer.iss
;
; Installing under %LOCALAPPDATA% keeps the install directory writable, which is
; what the in-app updater needs for its in-place replace. The portable zip stays
; available for people who do not want an installer.

#ifndef Version
  #define Version "0.0.0"
#endif

#ifndef LekisPayloadDir
  #error LekisPayloadDir must be defined
#endif

#ifndef LekisOutDir
  #define LekisOutDir "dist"
#endif

[Setup]
AppId={{8E4C2E7A-3B1D-4A6F-9C5E-2D7B1F0A6C93}
AppName=Lekis Music
AppVersion={#Version}
AppVerName=Lekis Music {#Version}
AppPublisher=Lekis Music
AppPublisherURL=https://github.com/aoxzh/lekis-music
AppSupportURL=https://github.com/aoxzh/lekis-music/issues
AppUpdatesURL=https://github.com/aoxzh/lekis-music/releases
DefaultDirName={localappdata}\Programs\Lekis
DefaultGroupName=Lekis Music
DisableProgramGroupPage=yes
LicenseFile=..\LICENSE
SetupIconFile=..\app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\lekis.exe
UninstallDisplayName=Lekis Music
OutputDir={#LekisOutDir}
OutputBaseFilename=lekis-{#Version}-windows-x64-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
MinVersion=10.0
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#LekisPayloadDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Lekis Music"; Filename: "{app}\lekis.exe"
Name: "{group}\Uninstall Lekis Music"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Lekis Music"; Filename: "{app}\lekis.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\lekis.exe"; Description: "{cm:LaunchProgram,Lekis Music}"; Flags: nowait postinstall skipifsilent
