#requires -Version 7.2
[CmdletBinding()]
param([string] $ConfigPath, [ValidateSet('MySQL','SQLAnywhere')][string] $Provider,
    [string] $InstanceName, [string] $InstancesRoot = (Join-Path $PSScriptRoot 'Instances'),
    [switch] $Apply, [switch] $Plan)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules/Core/Setup.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules/Core/Configuration.psm1')
Import-Module (Join-Path $PSScriptRoot 'Modules/Core/Runtime.psm1')
try {
    if ($Apply -and $Plan) { throw 'Choose -Apply or -Plan.' }
    $InstancesRoot = [IO.Path]::GetFullPath($InstancesRoot)
    if (-not $Plan) {
        if (-not $IsWindows) { throw 'DBBackup setup requires Windows.' }
        $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Execute setup as Administrator.' }
    }
    if (-not $ConfigPath) {
        if ($Apply -or $Plan) { $ConfigPath = Read-Host 'Caminho completo do config.psd1 existente' }
        else {
            if (-not $Provider) { $Provider = Read-Host 'Provedor: MySQL ou SQLAnywhere' }
            if ($Provider -cnotin @('MySQL','SQLAnywhere')) { throw 'Unknown provider.' }
            if (-not $InstanceName) { $InstanceName = Read-Host "Nome da instancia [$Provider]"; if (-not $InstanceName) { $InstanceName = $Provider } }
            Assert-DBIdentifier $InstanceName
            $ConfigPath = Join-Path $InstancesRoot "$InstanceName/config.psd1"
        }
    }
    $ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
    if (-not (Test-DBPathWithin $ConfigPath $InstancesRoot)) { throw 'Configuration must be inside InstancesRoot.' }
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        if ($Apply -or $Plan) { throw 'Configuration does not exist.' }
        if (-not $Provider) { throw 'Provider is required to create an instance.' }
        if (-not $InstanceName) { $InstanceName = Split-Path -Leaf (Split-Path $ConfigPath) }
        $null = Initialize-DBInstance -ConfigPath $ConfigPath -Provider $Provider -InstanceName $InstanceName -TemplateRoot (Join-Path $PSScriptRoot 'Templates') -InstancesRoot $InstancesRoot
    }
    if (-not $Apply -and -not $Plan) {
        $null = Read-DBConfiguration $ConfigPath
        Set-DBInteractiveConfiguration $ConfigPath
        Initialize-DBSecret (Read-DBConfiguration $ConfigPath)
    }
    Invoke-DBConfigurationApply -Configuration (Read-DBConfiguration $ConfigPath) -InstancesRoot $InstancesRoot `
        -ScriptPath (Join-Path $PSScriptRoot 'Backup.ps1') -PwshPath (Get-Process -Id $PID).Path -PlanOnly:$Plan
    exit 0
}
catch { Write-Error (Protect-DBMessage $_.Exception.Message) -ErrorAction Continue; exit 2 }
