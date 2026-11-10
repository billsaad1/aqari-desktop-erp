#define MyAppName "نظام إدارة العقارات والمحاسبة - مؤسسة عبدالله النقيب"
#define MyAppVersion "1.0.0"
#define MyAppExeName "aqari_erp.exe"

[Setup]
AppId={{D6DB6C3A-4E21-4E0B-9EE7-5A4D1D07A411}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher=مؤسسة عبدالله النقيب التجارية
DefaultDirName={localappdata}\Programs\AqariERP
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\build\windows\installer
OutputBaseFilename=Aqari-ERP-Setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
WizardStyle=modern
Compression=lzma2/ultra64
SolidCompression=yes
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "arabic"; MessagesFile: "compiler:Languages\Arabic.isl"

[Tasks]
Name: "desktopicon"; Description: "إنشاء اختصار على سطح المكتب"; GroupDescription: "اختصارات إضافية:"; Flags: checkedonce

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"
Name: "{autodesktop}\نظام إدارة العقارات والمحاسبة"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "تشغيل نظام إدارة العقارات والمحاسبة"; Flags: postinstall nowait skipifsilent
