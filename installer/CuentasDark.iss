; Instalador de Cuentas Dark para Windows (Inno Setup 6). Lo compila GitHub Actions:
;   iscc /DMyVersion=1.0.N installer\CuentasDark.iss
; Se instala para el usuario (no pide administrador) en %LOCALAPPDATA%\Programs\CuentasDark.
; Los datos NO van en la carpeta del programa: viven en %APPDATA%\CuentasDark y no se borran al
; actualizar ni al desinstalar.
#ifndef MyVersion
  #define MyVersion "1.0.0"
#endif
#define Build "..\build\windows\x64\runner\Release"

[Setup]
AppId={{6F3C9A52-4B7E-4D0E-9C1A-2B8D5E7F1A93}
AppName=Cuentas Dark
AppVersion={#MyVersion}
AppVerName=Cuentas Dark {#MyVersion}
AppPublisher=Ciber Dark
DefaultDirName={localappdata}\Programs\CuentasDark
DefaultGroupName=Cuentas Dark
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=CuentasDark-Setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\CuentasDark.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes

[Languages]
Name: "es"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "escritorio"; Description: "Crear un acceso directo en el escritorio"; GroupDescription: "Accesos directos:"

[Files]
Source: "{#Build}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Cuentas Dark"; Filename: "{app}\CuentasDark.exe"
Name: "{group}\Desinstalar Cuentas Dark"; Filename: "{uninstallexe}"
Name: "{userdesktop}\Cuentas Dark"; Filename: "{app}\CuentasDark.exe"; Tasks: escritorio

[Run]
Filename: "{app}\CuentasDark.exe"; Description: "Abrir Cuentas Dark"; Flags: nowait postinstall skipifsilent
