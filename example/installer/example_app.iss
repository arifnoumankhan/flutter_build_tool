; Inno Setup script for the example app (Windows installer).
; The build tool compiles it with these defines and copies the installer to
; dist\windows:
;   MyAppVersion   x.y.z (from pubspec.yaml)
;   MyOutputName   installer file name without .exe, e.g. ExampleApp-prod-v1.0.0
;   MyBuildMode    Flutter output folder to package: Release (default), Debug, Profile
; The script must name its output folder build\windows\installers and use
; {#MyOutputName} as OutputBaseFilename: the tool looks for the installer there.

#define MyAppName "Example App"
#define MyAppExeName "example_app.exe"

#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif
#ifndef MyOutputName
  #define MyOutputName "ExampleApp-Setup-" + MyAppVersion
#endif
#ifndef MyBuildMode
  #define MyBuildMode "Release"
#endif

[Setup]
AppId={{00000000-0000-0000-0000-000000000000}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
DefaultDirName={autopf}\{#MyAppName}
OutputDir=..\build\windows\installers
OutputBaseFilename={#MyOutputName}
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=lowest

[Files]
Source: "..\build\windows\x64\runner\{#MyBuildMode}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
