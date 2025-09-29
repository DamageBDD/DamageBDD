@echo off
setlocal enabledelayedexpansion
set ROOT=%~dp0
set PROJ=%ROOT%DamageBDD
set REBAR3=%PROJ%\rebar3

if not exist "%PROJ%" (
  echo [ERROR] DamageBDD not found at "%PROJ%".
  exit /b 1
)

rem Locate escript
for /f "usebackq delims=" %%E in (`powershell -NoProfile -Command "(Get-ChildItem 'C:\Program Files','C:\Program Files (x86)' -Filter escript.exe -Recurse -EA SilentlyContinue ^| Select-Object -First 1).FullName"`) do set ESCRIPT=%%E
if not exist "%ESCRIPT%" (
  echo [ERROR] Erlang escript.exe not found.
  exit /b 1
)

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

echo.
echo === DamageBDD ===
echo [1] Start (daemon)
echo [2] Stop
echo [3] Console (interactive)
echo [4] Show logs folder
echo [Q] Quit
set /p CH=Select option: 
if /I "%CH%"=="1" ( call "%REL_BIN%" start & exit /b 0 )
if /I "%CH%"=="2" ( call "%REL_BIN%" stop & exit /b 0 )
if /I "%CH%"=="3" ( call "%REL_BIN%" console & exit /b 0 )
if /I "%CH%"=="4" (
  for %%F in ("%REL_BIN%") do set REL_BIN_DIR=%%~dpF
  for %%F in ("%REL_BIN_DIR%\..") do set REL_ROOT=%%~fF
  explorer "%REL_ROOT%\log"
  exit /b 0
)
exit /b 0
