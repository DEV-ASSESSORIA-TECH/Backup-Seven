@echo off
setlocal
rem Aplica o config.psd1 atual (pastas, permissoes, testes e tarefas da secao Schedule), sem perguntar dados.
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

title BackupSeven - Aplicar configuracao
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-BackupSeven.ps1" -Apply
set "RESULT=%ERRORLEVEL%"
echo.
pause
exit /b %RESULT%
