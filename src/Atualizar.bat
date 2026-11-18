@echo off
setlocal
rem Atualiza o DBBackup para a ultima versao publicada no GitHub.
rem Sem internet: arraste o DBBackup-X.Y.Z.zip (com o .sha256 ao lado) sobre este arquivo.
set "DBBACKUP_PACKAGE=%~1"
net session >nul 2>&1
if errorlevel 1 (
    set "DBBACKUP_LAUNCHER=%~f0"
    powershell -NoProfile -Command "if ($env:DBBACKUP_PACKAGE) { Start-Process -FilePath $env:DBBACKUP_LAUNCHER -ArgumentList ([char]34 + $env:DBBACKUP_PACKAGE + [char]34) -Verb RunAs } else { Start-Process -FilePath $env:DBBACKUP_LAUNCHER -Verb RunAs }"
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
if not exist "%~dp0App\Update.ps1" (
    echo App\Update.ps1 nao encontrado ao lado deste arquivo.
    pause
    exit /b 1
)
title DBBackup - Atualizacao
set "DBBACKUP_UPDATER=%TEMP%\DBBackup-Update-%RANDOM%%RANDOM%.ps1"
rem A atualizacao substitui este .bat. O bloco abaixo e lido inteiro pelo cmd
rem antes de executar, entao a troca do arquivo nao interfere na execucao.
(
    copy /y "%~dp0App\Update.ps1" "%DBBACKUP_UPDATER%" >nul
    "%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%DBBACKUP_UPDATER%" -InstallRoot "%~dp0." -PackagePath "%DBBACKUP_PACKAGE%"
    del /q "%DBBACKUP_UPDATER%" >nul 2>&1
    pause
    exit /b
)
