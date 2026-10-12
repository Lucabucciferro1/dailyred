@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\windows.ps1" start %*
set "dailyred_exit=%errorlevel%"
if not "%dailyred_exit%"=="0" pause
exit /b %dailyred_exit%
