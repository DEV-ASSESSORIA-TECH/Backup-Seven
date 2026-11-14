@echo off
setlocal
rem Setup do BackupSeven: pergunta os dados, grava config.psd1 e Secrets e aplica a configuracao.
rem Pede elevacao (UAC) e executa o PowerShell 7 com -ExecutionPolicy Bypass.

net session >nul 2>&1
if errorlevel 1 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not exist "%PWSH%" (
    for /f "delims=" %%P in ('where pwsh.exe 2^>nul') do if not defined PWSH_FOUND set "PWSH_FOUND=%%P"
)
if defined PWSH_FOUND set "PWSH=%PWSH_FOUND%"
if not exist "%PWSH%" (
    echo PowerShell 7 nao encontrado. Instale o PowerShell 7 e tente de novo.
    pause
    exit /b 1
)

title BackupSeven - Setup
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-BackupSeven.ps1" 
set "RESULT=%ERRORLEVEL%"
echo.
pause
exit /b %RESULT%
