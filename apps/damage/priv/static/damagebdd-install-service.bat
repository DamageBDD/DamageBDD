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

rem --- Ensure tools dir
if not exist "%TOOLS%" mkdir "%TOOLS%"

rem --- Fetch NSSM (portable) if not present
if not exist "%NSSM_EXE%" (
  echo [INFO] Downloading NSSM...
  powershell -NoProfile -Command ^
    "$u='https://nssm.cc/release/nssm-2.24.zip';" ^
    "$z='%TOOLS%\nssm.zip';" ^
    "Invoke-WebRequest -Uri $u -OutFile $z; " ^
    "Expand-Archive -Path $z -DestinationPath '%TOOLS%' -Force; " ^
    "Remove-Item $z; " ^
    "$p=(Get-ChildItem -Recurse -Path '%TOOLS%' -Filter nssm.exe ^| Where-Object FullName -match 'win64').FullName; " ^
    "Copy-Item $p '%NSSM_EXE%' -Force"
  if errorlevel 1 (
    echo [ERROR] Failed to download/extract NSSM.
    exit /b 1
  )
)

rem --- Build release (if missing) and locate release root/bin
set ESCRIPT=
for /f "usebackq delims=" %%E in (`powershell -NoProfile -Command "(Get-ChildItem 'C:\Program Files','C:\Program Files (x86)' -Filter escript.exe -Recurse -EA SilentlyContinue ^| Select-Object -First 1).FullName"`) do set ESCRIPT=%%E
if not exist "%ESCRIPT%" (
  echo [ERROR] Couldn't find escript.exe. Is Erlang/OTP installed?
  exit /b 1
)

set REBAR3=%PROJ%\rebar3
set REL_BIN=
if not exist "%PROJ%\_build" (
  echo [INFO] Building release...
  pushd "%PROJ%"
  "%ESCRIPT%" "%REBAR3%" release || (echo [ERROR] rebar3 release failed & popd & exit /b 1)
  popd
)

for /f "delims=" %%B in ('dir /b /s "%PROJ%\_build\*\rel\*\bin\*.cmd" 2^>nul') do if not defined REL_BIN set REL_BIN=%%B
if not defined REL_BIN (
  echo [ERROR] Release launcher not found. Did 'rebar3 release' succeed?
  exit /b 1
)

rem --- Derive release root and name
for %%F in ("%REL_BIN%") do set REL_BIN_DIR=%%~dpF
for %%F in ("%REL_BIN_DIR%\..") do set REL_ROOT=%%~fF
for %%F in ("%REL_BIN%") do set REL_LAUNCHER=%%~nxF
set REL_NAME=%REL_LAUNCHER:.cmd=%

echo [INFO] Release root: %REL_ROOT%
echo [INFO] Release name: %REL_NAME%

rem --- Install service with NSSM (runs 'foreground' so service stays attached)
"%NSSM_EXE%" stop "%SERVICE_NAME%" >nul 2>nul
"%NSSM_EXE%" remove "%SERVICE_NAME%" confirm >nul 2>nul

"%NSSM_EXE%" install "%SERVICE_NAME%" "%REL_ROOT%\bin\%REL_NAME%.cmd" foreground
if errorlevel 1 (
  echo [ERROR] NSSM install failed.
  exit /b 1
)

"%NSSM_EXE%" set "%SERVICE_NAME%" DisplayName "%SERVICE_DISPLAY%"
"%NSSM_EXE%" set "%SERVICE_NAME%" Description "%SERVICE_DESC%"
"%NSSM_EXE%" set "%SERVICE_NAME%" AppDirectory "%REL_ROOT%"
"%NSSM_EXE%" set "%SERVICE_NAME%" Start SERVICE_AUTO_START
"%NSSM_EXE%" set "%SERVICE_NAME%" AppStopMethodConsole 15000
"%NSSM_EXE%" set "%SERVICE_NAME%" AppStopMethodSkip 0
"%NSSM_EXE%" set "%SERVICE_NAME%" AppStdout "%REL_ROOT%\log\service-stdout.log"
"%NSSM_EXE%" set "%SERVICE_NAME%" AppStderr "%REL_ROOT%\log\service-stderr.log"
"%NSSM_EXE%" set "%SERVICE_NAME%" AppRotateFiles 1
"%NSSM_EXE%" set "%SERVICE_NAME%" AppRotateOnline 1

sc start "%SERVICE_NAME%" >nul
if errorlevel 1 (
  echo [WARN] Service created but could not be started immediately. Try starting from Services.msc
) else (
  echo [OK] Service '%SERVICE_NAME%' installed and started.
)

rem --- Create a matching uninstall helper
(
  echo @echo off
  echo setlocal
  echo "%NSSM_EXE%" stop "%SERVICE_NAME%"
  echo "%NSSM_EXE%" remove "%SERVICE_NAME%" confirm
  echo echo [OK] Service "%SERVICE_NAME%" removed.
) > "%ROOT%damagebdd-uninstall-service.bat"

echo [OK] Uninstall helper written to damagebdd-uninstall-service.bat
exit /b 0
