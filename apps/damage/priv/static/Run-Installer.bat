@echo off
setlocal
set SCRIPT=%~dp0Install-DamageBDD.ps1
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Start-Process PowerShell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','\"%SCRIPT%\"'"
