@echo off
setlocal
net session >nul 2>&1
if errorlevel 1 (
    set "DBBACKUP_LAUNCHER=%~f0"
    powershell -NoProfile -Command "Start-Process -FilePath $env:DBBACKUP_LAUNCHER -Verb RunAs"
    exit /b
)
set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not exist "%PWSH%" set "PWSH="
rem Fallback: any pwsh.exe on PATH (other install locations or versions).
if not defined PWSH for /f "delims=" %%P in ('where pwsh.exe 2^>nul') do if not defined PWSH set "PWSH=%%P"
if not defined PWSH (
    echo Instale PowerShell 7.2 ou superior antes de continuar.
    pause
    exit /b 1
)
title DBBackup
rem Abre o config.psd1 da instancia escolhida como Administrador, valida e aplica.
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0App\Setup.ps1" -Edit
set "RESULT=%ERRORLEVEL%"
pause
exit /b %RESULT%
