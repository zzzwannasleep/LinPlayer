; Inno Setup script for packaging Flutter Windows build output into a setup.exe.
; Expects environment variables set by CI:
; - SOURCE_DIR : absolute path to Flutter Windows Release directory
; - OUTPUT_DIR : output directory for the generated installer
; - APP_VERSION: app version string
; - APP_ARCH   : architecture label (e.g. x64)

#define MyAppName "LinPlayer"
#define MyAppExeName "LinPlayer.exe"
#define MyAppVersion GetEnv("APP_VERSION")
#define MyAppVersionFull GetEnv("APP_VERSION_FULL")
#define MySourceDir GetEnv("SOURCE_DIR")
#define MyOutputDir GetEnv("OUTPUT_DIR")
#define MyArch GetEnv("APP_ARCH")

[Setup]
AppId={{B1C9C8E7-3F3F-4D6B-8D44-4C20C19E2B8A}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersionFull}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
AllowNoIcons=yes
OutputDir={#MyOutputDir}
OutputBaseFilename=LinPlayer-Setup-{#MyArch}
SetupIconFile=..\..\..\windows\runner\resources\app_icon.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop icon"; GroupDescription: "Additional icons:"; Flags: unchecked

[Files]
Source: "{#MySourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{commondesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent
