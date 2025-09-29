@echo off
setlocal

set ROOT=%~dp0
set PROJ=%ROOT%DamageBDD

set REL_BIN=
for /f "delims=" %%B in ('dir /b /s "%PROJ%\_build\*\rel\*\bin\*.cmd" 2^>nul') do if not defined REL_BIN set REL_BIN=%%B

if not defined REL_BIN (
  echo [ERROR] No release launcher found to stop.
  exit /b 1
)

echo [INFO] Using launcher: "%REL_BIN%"
call "%REL_BIN%" stop
echo [OK] DamageBDD stop command issued.
exit /b 0
