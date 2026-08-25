#define MyAppName "Tvoice"
#define MyAppVersion "0.17.10"
#define MyAppPublisher "SugdNet"
#define MyAppExeName "Tvoice.exe"
#define PublishDir "..\build\windows\x64\runner\Release"

[Setup]
AppId={{7D6DF24F-1671-4885-B159-C169BF6BC0B4}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\Tvoice
DefaultGroupName=Tvoice
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\artifacts
OutputBaseFilename=Tvoice-Windows-v0.17.10-Setup-x64
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes
RestartApplications=no
UninstallDisplayIcon={app}\{#MyAppExeName}
VersionInfoVersion={#MyAppVersion}
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription=Tvoice for Windows
VersionInfoProductName={#MyAppName}
SetupIconFile=..\windows\runner\resources\app_icon.ico

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Создать ярлык на рабочем столе"; GroupDescription: "Дополнительные значки:"; Flags: unchecked

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "*.pdb"

[Icons]
Name: "{autoprograms}\Tvoice"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\Tvoice"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Classes\tvoice"; ValueType: string; ValueName: ""; ValueData: "URL:Tvoice Conference Protocol"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\tvoice"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\tvoice\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{#MyAppExeName},0"
Root: HKCU; Subkey: "Software\Classes\tvoice\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%1"""

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Запустить Tvoice"; Flags: nowait postinstall skipifsilent

