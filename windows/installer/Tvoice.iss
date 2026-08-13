#define MyAppName "Tvoice"
#define MyAppVersion "1.1.0"
#define MyAppPublisher "SugdNet"
#define MyAppExeName "Tvoice.exe"
#define PublishDir "..\artifacts\Tvoice.Windows-x64"

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
OutputBaseFilename=Tvoice-Windows-Setup-1.1.0-x64
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

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Запустить Tvoice"; Flags: nowait postinstall skipifsilent
