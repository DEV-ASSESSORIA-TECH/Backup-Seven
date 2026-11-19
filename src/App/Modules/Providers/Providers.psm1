Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'MySQL/MySQL.psm1')
Import-Module (Join-Path $PSScriptRoot 'Directory/Directory.psm1')

function Invoke-DBProvider {
    <# Mode Incremental exists only for SQL Anywhere jobs with Incremental.Enabled; Base is the base full. #>
    param([Collections.IDictionary] $Configuration, $Job, $Runtime, [ValidateSet('Full','Incremental')][string] $Mode = 'Full', $Base)
    if ($Mode -eq 'Incremental' -and $Job.Provider -ne 'SQLAnywhere') { throw "Job $($Job.Id): incremental is only supported for SQL Anywhere." }
    switch ($Job.Provider) {
        MySQL { return Invoke-DBMySql -Configuration $Configuration -Job $Job -Runtime $Runtime }
        Directory { return Invoke-DBDirectory -Configuration $Configuration -Job $Job -Runtime $Runtime }
        SQLAnywhere {
            $module = Join-Path $PSScriptRoot 'SQLAnywhere/SQLAnywhere.psm1'
            Import-Module $module
            return Invoke-DBSqlAnywhere -Configuration $Configuration -Job $Job -Runtime $Runtime -Mode $Mode -Base $Base
        }
        default { throw "Unknown provider: $($Job.Provider)" }
    }
}

function Get-DBProviderSizeEstimate {
    <# Cheap provider-side size probe in bytes, or $null when the provider has none. #>
    param([Collections.IDictionary] $Configuration, $Job, $Runtime)
    switch ($Job.Provider) {
        MySQL { return Get-DBMySqlSizeEstimate -Configuration $Configuration -Job $Job }
        SQLAnywhere {
            Import-Module (Join-Path $PSScriptRoot 'SQLAnywhere/SQLAnywhere.psm1')
            return Get-DBSqlAnywhereSizeEstimate -Configuration $Configuration -Job $Job -Runtime $Runtime
        }
        default { return $null }
    }
}
Export-ModuleMember -Function Invoke-DBProvider, Get-DBProviderSizeEstimate
