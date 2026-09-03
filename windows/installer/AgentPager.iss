#ifndef AppVersion
  #define AppVersion "0.3.1"
#endif
#ifndef PublishDir
  #define PublishDir "..\..\dist\windows-publish"
#endif

[Setup]
AppId={{9EAE3F9B-AE27-4B2B-B19E-43AA4E078B07}
AppName=AgentPager Bridge
AppVersion={#AppVersion}
AppPublisher=AgentPager
AppPublisherURL=https://github.com/
DefaultDirName={localappdata}\Programs\AgentPager
DefaultGroupName=AgentPager
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputBaseFilename=AgentPager-Windows-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=AgentPager Bridge
CloseApplications=yes
RestartApplications=no

[Files]
Source: "{#PublishDir}\AgentPagerBridge.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\AgentPager Bridge"; Filename: "{app}\AgentPagerBridge.exe"
Name: "{userdesktop}\AgentPager Bridge"; Filename: "{app}\AgentPagerBridge.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Run]
Filename: "{app}\AgentPagerBridge.exe"; Parameters: "--first-run"; Description: "Launch AgentPager Bridge"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{app}\AgentPagerBridge.exe"; Parameters: "--uninstall-hook"; Flags: runhidden waituntilterminated; RunOnceId: "RemoveAgentPagerHook"
