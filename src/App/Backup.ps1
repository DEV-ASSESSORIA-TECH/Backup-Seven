#requires -Version 7.2
[CmdletBinding()]
param(
    # Required for scheduled tasks; the menu (-Interactive) lets the operator choose.
    [string] $ConfigPath,
    # One job ID or a comma-separated list (scheduled tasks pass "a,b").
    [string] $Job,
    [switch] $All,
    # Incremental: cumulative transaction log of SQL Anywhere jobs with Incremental.Enabled.
    [ValidateSet('Full','Incremental')][string] $Mode = 'Full',
    # Operator run: choose instance and jobs, and show each log line on screen.
    [switch] $Interactive,
    [string] $InstancesRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Instances')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules/Core/Runner.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules/Core/Configuration.psm1')
Import-Module (Join-Path $PSScriptRoot 'Modules/Core/Runtime.psm1')
if ($Interactive) {
    try {
        if (-not $ConfigPath) { $ConfigPath = Select-DBConfigPath $InstancesRoot }
        if (-not $Job -and -not $All) {
            $configuration = Read-DBConfiguration $ConfigPath
            if (@($configuration.Jobs | Where-Object { $_.Incremental }).Count -and -not $PSBoundParameters.ContainsKey('Mode')) {
                $kind = ([string] (Read-Host 'Tipo: 1 = completo, 2 = incremental (Enter = completo)')).Trim()
                if ($kind -eq '2') { $Mode = 'Incremental' }
            }
            $listed = if ($Mode -eq 'Incremental') { @($configuration.Jobs | Where-Object { $_.Incremental }) } else { @($configuration.Jobs) }
            "Jobs desta instancia: $(@($listed.Id) -join ', ')" | Out-Host
            $answer = ([string] (Read-Host 'Jobs a executar (Enter = todos; ou IDs separados por virgula)')).Trim()
            if ($answer) { $Job = $answer } else { $All = [switch]::Present }
        }
    }
    catch { Write-Error (Protect-DBMessage $_.Exception.Message) -ErrorAction Continue; exit 2 }
    Set-DBConsoleLog $true
    'Iniciando o backup; o andamento aparece abaixo e no log da instancia.' | Out-Host
}
if (-not $ConfigPath) { Write-Error 'Informe -ConfigPath.' -ErrorAction Continue; exit 2 }
if ([bool] $Job -eq [bool] $All) { Write-Error 'Informe -Job <id[,id]> ou -All.' -ErrorAction Continue; exit 2 }
$code = Invoke-DBBackup -ConfigPath $ConfigPath -Job $Job -All:$All -Mode $Mode
if ($Interactive) {
    $meaning = switch ($code) { 0 { 'sucesso' } 1 { 'falha' } 2 { 'erro de configuracao' } 3 { 'outra execucao desta instancia ja esta em andamento' } 4 { 'backup feito, etapa auxiliar com falha' } 5 { 'backup degradado' } default { 'falha' } }
    "`nResultado: $meaning (exit $code)." | Out-Host
}
exit $code
