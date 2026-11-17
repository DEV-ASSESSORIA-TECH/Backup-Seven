BeforeAll {
    $script:Repo = Split-Path -Parent $PSScriptRoot
    Import-Module "$script:Repo/src/Modules/Providers/MySQL/MySQL.psm1" -Force
    Import-Module "$script:Repo/src/Modules/Providers/Directory/Directory.psm1" -Force
}
Describe 'MySQL provider outcomes' {
    BeforeEach {
        $script:C = @{Tools=@{MySqlDump='fake'; MySql='fake'}; Database=@{Name='db'; DefaultsExtraFile='secret'; ExtraArguments=@()}}
        $script:J = [pscustomobject]@{Id='database'}
        $script:R = [pscustomobject]@{Work=(Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))}
        Mock Invoke-MySqlDatabaseDump {
            param($OutputPath)
            Set-Content $OutputPath 'SQL'
            [pscustomobject]@{ExitCode=0; IsNonEmpty=$true; StdErr=''; File=(Get-Item $OutputPath)}
        } -ModuleName MySQL
        Mock Get-MySqlDatabaseObject { [pscustomobject]@{Name='table'; ObjectType='BASE TABLE'} } -ModuleName MySQL
    }
    It 'returns a normal payload without uploading' {
        $r = Invoke-DBMySql $script:C $script:J $script:R
        $r.Status | Should -Be SUCCESS
        $r.Packages.Count | Should -Be 1
    }
    It 'returns both degraded roles when normal dump fails' {
        Mock Invoke-MySqlDatabaseDump {
            param($OutputPath, $Force, $DatabaseObject)
            Set-Content $OutputPath 'SQL'
            [pscustomobject]@{ExitCode= $(if (-not $Force -and -not $DatabaseObject) {2} else {0}); IsNonEmpty=$true; StdErr='broken table'; File=(Get-Item $OutputPath)}
        } -ModuleName MySQL
        $r = Invoke-DBMySql $script:C $script:J $script:R
        $r.Status | Should -Be DEGRADED
        $r.Packages.Role | Should -Be @('GENERAL','GRANULAR')
    }
    It 'retains the general package on enumeration failure' {
        Mock Invoke-MySqlDatabaseDump {
            param($OutputPath)
            Set-Content $OutputPath 'partial SQL'
            [pscustomobject]@{ExitCode=2; IsNonEmpty=$true; StdErr='broken'; File=(Get-Item $OutputPath)}
        } -ModuleName MySQL
        Mock Get-MySqlDatabaseObject { throw 'enumeration failed' } -ModuleName MySQL
        $r = Invoke-DBMySql $script:C $script:J $script:R
        $r.Status | Should -Be FAILED
        $r.Packages.Role | Should -Be @('GENERAL')
    }
    It 'rejects options that redirect dumps or expose a password' {
        $script:C.Database.ExtraArguments=@('--result-file=elsewhere')
        { Invoke-DBMySql $script:C $script:J $script:R } | Should -Throw '*Unsafe*'
    }
}
Describe 'Generic directory job' {
    It 'stages hidden files and keeps user manifests below content' {
        $source=Join-Path $TestDrive 'source'
        $null=New-Item -ItemType Directory $source
        Set-Content (Join-Path $source 'manifest.json') '{"user":true}'
        $r=Invoke-DBDirectory @{} ([pscustomobject]@{Id='files';SourcePath=$source}) ([pscustomobject]@{Work=(Join-Path $TestDrive 'work')})
        $r.Status | Should -Be SUCCESS
        Test-Path (Join-Path $r.Packages[0].SourcePath 'content/manifest.json') | Should -BeTrue
    }
}
