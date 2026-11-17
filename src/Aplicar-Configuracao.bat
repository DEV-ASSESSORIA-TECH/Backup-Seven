@echo off
setlocal
net session >nul 2>&1
if errorlevel 1 (
    set "DBBACKUP_LAUNCHER=%~f0"
    powershell -NoProfile -Command "Start-Process -FilePath $env:DBBACKUP_LAUNCHER -Verb RunAs"
    exit /b
)
set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not exist "%PWSH%" (
    echo Instale PowerShell 7 antes de continuar.
    pause
    exit /b 1
)
title DBBackup
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup.ps1" -Apply
set "RESULT=%ERRORLEVEL%"
pause
exit /b %RESULT%
