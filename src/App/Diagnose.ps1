#requires -Version 7.2
[CmdletBinding()]
param([string] $ConfigPath, [string] $InstancesRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Instances'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules/Core/Setup.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules/Core/Configuration.psm1')
Import-Module (Join-Path $PSScriptRoot 'Modules/Core/Runtime.psm1')
try {
    if (-not $ConfigPath) { $ConfigPath = Select-DBConfigPath $InstancesRoot }
    $configuration = Read-DBConfiguration $ConfigPath
    Test-DBInstance -Configuration $configuration -InstancesRoot $InstancesRoot
    exit 0
}
catch { Write-Error (Protect-DBMessage $_.Exception.Message) -ErrorAction Continue; exit 2 }
