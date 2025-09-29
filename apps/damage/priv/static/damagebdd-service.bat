@echo off
setlocal enabledelayedexpansion

set ROOT=%~dp0
set PROJ=%ROOT%DamageBDD
set TOOLS=%ROOT%tools
set NSSM_EXE=%TOOLS%\nssm.exe
set SERVICE_NAME=DamageBDD
set SERVICE_DISPLAY=DamageBDD Service
set SERVICE_DESC=DamageBDD Erlang release managed by NSSM

if not exist "%PROJ%" (
  echo [ERROR] DamageBDD not found at "%PROJ%".
  exit /b 1
)

rem Fetch nssm portable if missing
if not exist "%TOOLS%" mkdir "%TOOLS%"
if not exist "%NSSM_EXE%" (
  echo [INFO] Downloading NSSM...
  powershell -NoProfile -Command ^
    "$u='https://nssm.cc/release/nssm-2.24.zip';$z='%TOOLS%\nssm.zip';" ^
    "Invoke-WebRequest -Uri $u -OutFile $z;Expand-Archive -Path $z -DestinationPath '%TOOLS%' -Force;Remove-Item $z;" ^
    "$p=(Get-ChildItem -Recurse -Path '%TOOLS%' -Filter nssm.exe ^| Where-Object FullName -match 'win64').FullName;" ^
    "Copy-Item $p '%NSSM_EXE%' -Force" || (echo [ERROR] NSSM download failed. & exit /b 1)
)

rem Find release bin (build if needed)
for /f "usebackq delims=" %%E in (`powershell -NoProfile -Command "(Get-ChildItem 'C:\Program Files','C:\Program Files (x86)' -Filter escript.exe -Recurse -EA SilentlyContinue ^| Select-Object -First 1).FullName"`) do set ESCRIPT=%%E
set REBAR3=%PROJ%\rebar3
set REL_BIN=
for /f "delims=" %%B in ('dir /b /s "%PROJ%\_build\*\rel\*\bin\*.cmd" 2^>nul') do if not defined REL_BIN set REL_BIN=%%B
if not defined REL_BIN (
  echo [INFO] Building release...
  pushd "%PROJ%"
  "%ESCRIPT%" "%REBAR3%" release || (echo [ERROR] rebar3 release failed & popd & exit /b 1)
  popd
  for /f "delims=" %%B in ('dir /b /s "%PROJ%\_build\*\rel\*\bin\*.cmd" 2^>nul') do if not defined REL_BIN set REL_BIN=%%B
  if not defined REL_BIN ( echo [ERROR] Release not found after build. & exit /b 1 )
)

for %%F in ("%REL_BIN%") do set REL_BIN_DIR=%%~dpF
for %%F in ("%REL_BIN_DIR%\..") do set REL_ROOT=%%~fF
for %%F in ("%REL_BIN%") do set REL_NAME=%%~nF

echo.
echo === DamageBDD Windows Service ===
echo [1] Install (auto-start)
echo [2] Start
echo [3] Stop
echo [4] Uninstall
echo [Q] Quit
set /p CH=Select option: 

if /I "%CH%"=="1" (
  "%NSSM_EXE%" stop "%SERVICE_NAME%" >nul 2>nul
  "%NSSM_EXE%" remove "%SERVICE_NAME%" confirm >nul 2>nul

  "%NSSM_EXE%" install "%SERVICE_NAME%" "%REL_ROOT%\bin\%REL_NAME%.cmd" foreground || (echo [ERROR] NSSM install failed. & exit /b 1)
  "%NSSM_EXE%" set "%SERVICE_NAME%" DisplayName "%SERVICE_DISPLAY%"
  "%NSSM_EXE%" set "%SERVICE_NAME%" Description "%SERVICE_DESC%"
  "%NSSM_EXE%" set "%SERVICE_NAME%" AppDirectory "%REL_ROOT%"
  "%NSSM_EXE%" set "%SERVICE_NAME%" Start SERVICE_AUTO_START
  "%NSSM_EXE%" set "%SERVICE_NAME%" AppStopMethodConsole 15000
  "%NSSM_EXE%" set "%SERVICE_NAME%" AppStdout "%REL_ROOT%\log\service-stdout.log"
  "%NSSM_EXE%" set "%SERVICE_NAME%" AppStderr "%REL_ROOT%\log\service-stderr.log"
  "%NSSM_EXE%" set "%SERVICE_NAME%" AppRotateFiles 1
  "%NSSM_EXE%" set "%SERVICE_NAME%" AppRotateOnline 1

  echo.
  set /p STOREPW=Set DAMAGE_SECRET_KEY in the service for non-interactive unlock? (y/N): 
  if /I "%STOREPW%"=="Y" (
    set /p PWVAL=Enter DAMAGE_SECRET_KEY (will be stored in the service definition): 
    "%NSSM_EXE%" set "%SERVICE_NAME%" AppEnvironmentExtra "DAMAGE_SECRET_KEY=%PWVAL%"
  )

  sc start "%SERVICE_NAME%" >nul || echo [OK] Service installed. Start it from Services.msc if needed.
  echo [OK] Done.
  exit /b 0
)

if /I "%CH%"=="2" ( sc start "%SERVICE_NAME%" & exit /b 0 )
if /I "%CH%"=="3" ( sc stop  "%SERVICE_NAME%" & exit /b 0 )
if /I "%CH%"=="4" (
  "%NSSM_EXE%" stop "%SERVICE_NAME%" >nul 2>nul
  "%NSSM_EXE%" remove "%SERVICE_NAME%" confirm
  echo [OK] Service removed.
  exit /b 0
)
exit /b 0
