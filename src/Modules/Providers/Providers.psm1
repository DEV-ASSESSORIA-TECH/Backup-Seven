Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'MySQL/MySQL.psm1')
Import-Module (Join-Path $PSScriptRoot 'Directory/Directory.psm1')

function Invoke-DBProvider {
    param([Collections.IDictionary] $Configuration, $Job, $Runtime)
    switch ($Job.Provider) {
        MySQL { return Invoke-DBMySql -Configuration $Configuration -Job $Job -Runtime $Runtime }
        Directory { return Invoke-DBDirectory -Configuration $Configuration -Job $Job -Runtime $Runtime }
        SQLAnywhere {
            $module = Join-Path $PSScriptRoot 'SQLAnywhere/SQLAnywhere.psm1'
            if (-not (Test-Path -LiteralPath $module)) { throw 'SQL Anywhere provider is not included in this development snapshot.' }
            Import-Module $module
            return Invoke-DBSqlAnywhere -Configuration $Configuration -Job $Job -Runtime $Runtime
        }
        default { throw "Unknown provider: $($Job.Provider)" }
    }
}
Export-ModuleMember -Function Invoke-DBProvider
