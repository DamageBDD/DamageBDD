@echo off
setlocal enabledelayedexpansion

rem --- Paths ---
set ROOT=%~dp0
set PROJ=%ROOT%DamageBDD
set REBAR3=%PROJ%\rebar3

if not exist "%PROJ%" (
  echo [ERROR] DamageBDD not found at "%PROJ%".
  exit /b 1
)

rem --- Locate escript.exe (from Erlang) ---
set ESCRIPT=
for /f "usebackq delims=" %%E in (`powershell -NoProfile -Command "(Get-ChildItem 'C:\Program Files','C:\Program Files (x86)' -Filter escript.exe -Recurse -EA SilentlyContinue ^| Select-Object -First 1).FullName"`) do set ESCRIPT=%%E
if not exist "%ESCRIPT%" (
  echo [ERROR] Couldn't find escript.exe. Is Erlang/OTP installed?
  exit /b 1
)

rem --- Ensure release exists ---
set REL_BIN=
for /f "delims=" %%B in ('dir /b /s "%PROJ%\_build\*\rel\*\bin\*.cmd" 2^>nul') do if not defined REL_BIN set REL_BIN=%%B

if not defined REL_BIN (
  echo [INFO] No release found. Building release...
  pushd "%PROJ%"
  "%ESCRIPT%" "%REBAR3%" release || (echo [ERROR] rebar3 release failed & popd & exit /b 1)
  popd

  for /f "delims=" %%B in ('dir /b /s "%PROJ%\_build\*\rel\*\bin\*.cmd" 2^>nul') do if not defined REL_BIN set REL_BIN=%%B
  if not defined REL_BIN (
    echo [ERROR] Release bin not found after build.
    exit /b 1
  )
)

echo [INFO] Using launcher: "%REL_BIN%"
call "%REL_BIN%" start
if errorlevel 1 (
  echo [WARN] 'start' may daemonize and still return nonzero. Trying 'console'...
  call "%REL_BIN%" console
)
echo [OK] DamageBDD start command issued.
exit /b 0
