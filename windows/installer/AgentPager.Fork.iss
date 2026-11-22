; Fork installer derived from AgentPager.iss (upstream AgentPager, GPL-3.0).
; Bridge runtime state is shared across builds: only remove installer-owned files.
#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef PayloadDir
  #error PayloadDir is required
#endif

[Setup]
AppId={{02EB8B83-FD7F-4A1F-892F-7B3B8DF1A49E}
AppName=AgentPager Bridge (Unofficial Extension)
AppVersion={#AppVersion}
AppPublisher=AgentPager community fork (unofficial)
DefaultDirName={localappdata}\Programs\AgentPager Extension
DefaultGroupName=AgentPager Extension
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputBaseFilename=AgentPager-Windows-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
Uninstallable=yes
UninstallDisplayName=AgentPager Bridge (Unofficial Extension)
UninstallDisplayIcon={app}\AgentPagerBridge.exe
CloseApplications=yes
CloseApplicationsFilter=AgentPagerBridge.exe
RestartApplications=no

[Files]
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs

[Icons]
Name: "{autoprograms}\AgentPager Extension\AgentPager Bridge"; Filename: "{app}\AgentPagerBridge.exe"; WorkingDir: "{app}"
Name: "{userdesktop}\AgentPager Bridge (Unofficial Extension)"; Filename: "{app}\AgentPagerBridge.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Run]
Filename: "{app}\AgentPagerBridge.exe"; Parameters: "--first-run"; Description: "Launch AgentPager Bridge"; Flags: nowait postinstall skipifsilent unchecked
