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
UninstallDisplayName={code:GetLocalizedAppName}
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
Name: "{group}\{code:GetLocalizedAppName}"; Filename: "{app}\lekis.exe"
Name: "{group}\{code:GetLocalizedUninstallName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{code:GetLocalizedAppName}"; Filename: "{app}\lekis.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\lekis.exe"; Description: "{code:GetLocalizedLaunchLabel}"; Flags: nowait postinstall skipifsilent

[Code]
function IsChineseUILanguage: Boolean;
begin
  { PRIMARYLANGID(GetUILanguage) == LANG_CHINESE (0x04) }
  Result := (GetUILanguage and $3FF) = $04;
end;

function GetLocalizedAppName(Param: String): String;
begin
  if IsChineseUILanguage then
    Result := #$6708#$5154#$97F3#$4E50
  else
    Result := 'Lekis Music';
end;

function GetLocalizedUninstallName(Param: String): String;
begin
  if IsChineseUILanguage then
    Result := #$5378#$8F7D' '#$6708#$5154#$97F3#$4E50
  else
    Result := 'Uninstall Lekis Music';
end;

function GetLocalizedLaunchLabel(Param: String): String;
begin
  if IsChineseUILanguage then
    Result := #$542F#$52A8' '#$6708#$5154#$97F3#$4E50
  else
    Result := 'Launch Lekis Music';
end;
