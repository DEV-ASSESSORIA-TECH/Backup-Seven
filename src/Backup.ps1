#requires -Version 7.2
[CmdletBinding(DefaultParameterSetName = 'Job')]
param(
    [Parameter(Mandatory)][string] $ConfigPath,
    [Parameter(Mandatory, ParameterSetName = 'Job')][string] $Job,
    [Parameter(Mandatory, ParameterSetName = 'All')][switch] $All
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules/Core/Runner.psm1') -Force
exit (Invoke-DBBackup -ConfigPath $ConfigPath -Job $Job -All:$All)
