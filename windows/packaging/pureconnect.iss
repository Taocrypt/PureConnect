; Inno Setup script for PureConnect (Windows x64).
;   iscc /DMyAppVersion=1.0.0 /DSourceDir=build\windows\x64\runner\Release windows\packaging\pureconnect.iss
; The app runs per user; the installer needs admin only for Program Files.

#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\dist"
#endif

[Setup]
AppId={{6D2F3C1B-7E0A-4B4C-9C55-2D7A9A1E5C31}
AppName=PureConnect
AppVersion={#MyAppVersion}
AppPublisher=taocrypt
DefaultDirName={autopf}\PureConnect
DefaultGroupName=PureConnect
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=PureConnect-{#MyAppVersion}-windows-x64-setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\pureconnect.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequiredOverridesAllowed=dialog
; Closes a running PureConnect (and its core) before replacing files.
CloseApplications=yes
RestartApplications=no

[Languages]
#if FileExists(AddBackslash(CompilerPath) + "Languages\ChineseSimplified.isl")
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
#endif
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\PureConnect"; Filename: "{app}\pureconnect.exe"
Name: "{autodesktop}\PureConnect"; Filename: "{app}\pureconnect.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\pureconnect.exe"; Description: "{cm:LaunchProgram,PureConnect}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Stop a core left running (e.g. elevated TUN core) so its files can be removed.
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM zjuconnect-core.exe"; Flags: runhidden; RunOnceId: "KillCore"

[Registry]
; Launch-at-login entry written by the app.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueName: "PureConnect"; Flags: uninsdeletevalue dontcreatekey
