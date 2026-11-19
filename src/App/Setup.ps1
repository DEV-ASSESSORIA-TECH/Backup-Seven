#requires -Version 7.2
[CmdletBinding()]
param([string] $ConfigPath, [string] $InstanceName,
    # <root>\Instances beside the App folder (<root>\App\Setup.ps1).
    [string] $InstancesRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Instances'),
    [switch] $Apply, [switch] $Plan,
    # Editar-Configuracao.bat: open config.psd1 elevated, validate, then apply.
    [switch] $Edit)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules/Core/Setup.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules/Core/Configuration.psm1')
Import-Module (Join-Path $PSScriptRoot 'Modules/Core/Runtime.psm1')
Import-Module (Join-Path $PSScriptRoot 'Modules/Core/Schedule.psm1')
# Set once the configuration and credentials are on disk, so a later failure
# tells the operator that nothing needs to be typed again.
$savedConfigPath = $null
try {
    if (@($Apply, $Plan, $Edit | Where-Object { $_ }).Count -gt 1) { throw 'Choose -Apply, -Plan or -Edit.' }
    $InstancesRoot = [IO.Path]::GetFullPath($InstancesRoot)
    if (-not $Plan) {
        if (-not $IsWindows) { throw 'DBBackup setup requires Windows.' }
        $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Execute setup as Administrator.' }
    }
    if ($Apply -or $Plan -or $Edit) {
        if (-not $ConfigPath) { $ConfigPath = Select-DBConfigPath $InstancesRoot }
        $ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
        if (-not (Test-DBPathWithin $ConfigPath $InstancesRoot)) { throw 'Configuration must be inside InstancesRoot.' }
        if (-not (Test-Path -LiteralPath $ConfigPath)) { throw 'Configuration does not exist.' }
        if ($Edit) {
            if (-not (Edit-DBConfiguration -ConfigPath $ConfigPath -InstancesRoot $InstancesRoot)) { exit 0 }
            $Apply = [switch]::Present
        }
        if ($Apply) { $savedConfigPath = $ConfigPath }
    }
    else {
        if ($ConfigPath) { $InstanceName = Split-Path -Leaf (Split-Path -Parent ([IO.Path]::GetFullPath($ConfigPath))) }
        $ConfigPath = Invoke-DBInteractiveSetup -InstancesRoot $InstancesRoot -TemplateRoot (Join-Path $PSScriptRoot 'Templates') -InstanceName $InstanceName
        $savedConfigPath = $ConfigPath
        if (-not (Invoke-DBConnectionCheck (Read-DBConfiguration $ConfigPath))) {
            throw 'Setup interrompido apos o teste de conexao.'
        }
    }
    $pwshPath = (Get-Process -Id $PID).Path
    if ($pwshPath -match '\\WindowsApps\\') {
        # Store/MSIX paths are versioned and may be unreadable by SYSTEM.
        Write-Warning "PowerShell em $pwshPath foi instalado pela Microsoft Store; a tarefa agendada (SYSTEM) pode nao conseguir executa-lo. Prefira o instalador MSI do PowerShell 7."
    }
    $scriptPath = Join-Path $PSScriptRoot 'Backup.ps1'
    Invoke-DBConfigurationApply -Configuration (Read-DBConfiguration $ConfigPath) -InstancesRoot $InstancesRoot `
        -ScriptPath $scriptPath -PwshPath $pwshPath -PlanOnly:$Plan
    if (-not $Plan) {
        $configuration = Read-DBConfiguration $ConfigPath
        $registered = @()
        if ($configuration.Contains('Schedule')) {
            $registered = @(Get-DBOwnedTask -Configuration $configuration -Existing @(Get-DBSchedulerSnapshot (Get-DBTaskFolder)) | ForEach-Object Name)
        }
        Get-DBSetupSummary -Configuration $configuration -RegisteredTasks $registered -PwshPath $pwshPath -ScriptPath $scriptPath | Out-Host
    }
    exit 0
}
catch {
    Write-Error (Protect-DBMessage $_.Exception.Message) -ErrorAction Continue
    if ($savedConfigPath) {
        @(
            ''
            "A configuracao e as credenciais ja estao salvas em $(Split-Path -Parent $savedConfigPath)."
            'Corrija o problema acima e rode Aplicar-Configuracao.bat informando este arquivo (nada sera perguntado de novo):'
            "  $savedConfigPath"
        ) | Out-Host
    }
    exit 2
}
