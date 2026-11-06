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

; App-local VC++ 2015-2022 CRT, copied at compile time from this PC's Visual
; Studio / Build Tools redist (installer\copy_vc_crt.ps1). The [Files] entry
; below then packs the DLLs next to the exe. About 1 MB. Not vc_redist.x64.exe.
#if Exec("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File """ + AddBackslash(SourcePath) + "copy_vc_crt.ps1"" -Destination """ + AddBackslash(SourcePath) + "..\build\windows\x64\runner\" + MyBuildMode + """", SourcePath, 1, SW_HIDE) != 0
  #error VC++ runtime DLLs were not copied. Install Visual Studio 2022 or Build Tools with the Desktop development with C++ workload, build the Windows app, then compile this script again. See installer/copy_vc_crt.ps1.
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
