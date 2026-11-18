BeforeAll {
    $script:Repo = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'V1.TestSupport.ps1')
    foreach ($module in @('Configuration','Runtime','Process','Capacity','Monitoring','Observation','Runner')) { Import-Module "$script:Repo/src/App/Modules/Core/$module.psm1" }
}
Describe 'Bounded native tools and disk checks' {
    BeforeAll { $script:FixtureConfig = New-DBTestFixture (Join-Path $TestDrive 'opsfixture') $script:Repo }
    It 'streams native output to disk without retaining the dump in memory' {
        $c = Read-DBConfiguration $script:FixtureConfig
        $out = Join-Path $TestDrive 'stream.sql'
        $r = Invoke-DBTool -Executable $c.Tools.MySqlDump -Arguments @('--databases','db') -OutputPath $out -TimeoutSeconds 5
        $r.ExitCode | Should -Be 0
        $r.StdOut | Should -BeNullOrEmpty
        $r.File.Length | Should -BeGreaterThan 0
        { Invoke-DBTool -Executable $c.Tools.MySqlDump -Arguments @('--databases','db') -OutputPath $out } | Should -Throw
    }
    It 'terminates the timed-out process tree including a native child' {
        $c = Read-DBConfiguration $script:FixtureConfig
        $marker = Join-Path $TestDrive 'child.pid'
        try {
            { Invoke-DBTool -Executable $c.Tools.Age -Arguments @('--spawn-child',$marker) -TimeoutSeconds 2 } | Should -Throw '*timeout*'
            Test-Path $marker | Should -BeTrue
            $childId = [int] (Get-Content $marker)
            $child = Get-Process -Id $childId -ErrorAction SilentlyContinue
            ($null -eq $child -or $child.HasExited) | Should -BeTrue
        }
        finally {
            if (Test-Path $marker) {
                $child = Get-Process -Id ([int] (Get-Content $marker)) -ErrorAction SilentlyContinue
                if ($null -ne $child -and -not $child.HasExited) { $child.Kill($true) }
            }
        }
    }
    It 'refuses to start a tool after the run deadline and shortens tools to it' {
        $c = Read-DBConfiguration $script:FixtureConfig
        try {
            Set-DBToolDeadline ([DateTime]::UtcNow.AddSeconds(-1))
            { Invoke-DBTool -Executable $c.Tools.Age -Arguments @('--sleep','10') -TimeoutSeconds 60 } | Should -Throw '*deadline*'
            Set-DBToolDeadline ([DateTime]::UtcNow.AddSeconds(1))
            $watch = [Diagnostics.Stopwatch]::StartNew()
            { Invoke-DBTool -Executable $c.Tools.Age -Arguments @('--sleep','20000') -TimeoutSeconds 60 } | Should -Throw '*run deadline*'
            $watch.Elapsed.TotalSeconds | Should -BeLessThan 15
        }
        finally { Set-DBToolDeadline $null }
        (Invoke-DBTool -Executable $c.Tools.Age -Arguments @('--sleep','10') -TimeoutSeconds 60).ExitCode | Should -Be 0
    }
    It 'reserves free space before accepting a stage estimate' {
        Mock Get-DBAvailableSpace { 1000 } -ModuleName Capacity
        { Assert-DBFreeSpace -Path $TestDrive -RequiredBytes 800 -ReserveBytes 300 } | Should -Throw '*Insufficient*'
        { Assert-DBFreeSpace -Path $TestDrive -RequiredBytes 700 -ReserveBytes 300 } | Should -Not -Throw
    }
}
Describe 'Monitoring operational integration' {
    BeforeAll { $script:FixtureConfig = New-DBTestFixture (Join-Path $TestDrive 'metricfixture') $script:Repo }
    BeforeEach {
        Clear-DBTestEnvironment
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory $script:Root
        Copy-Item (Split-Path $script:FixtureConfig) (Join-Path $script:Root 'instance') -Recurse
        $script:Config = Join-Path $script:Root 'instance/config.psd1'
        $script:Textfile = Join-Path $script:Root 'textfile'
        $null = New-Item -ItemType Directory $script:Textfile
        $text=(Get-Content $script:Config -Raw).Replace('Enabled = $false; Service', 'Enabled = $true; Service')
        $text=$text.Replace('C:\ProgramData\GrafanaLabs\Alloy\textfile\backup', $script:Textfile.Replace("'","''"))
        Set-Content $script:Config $text
        Mock Set-Acl {} -ModuleName Runtime
        Mock Write-Error {} -ModuleName Runner
    }
    AfterEach { Clear-DBTestEnvironment }
    It 'uses the exact HELP/TYPE contract and publishes provider/version labels' {
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 0
        $metric=Get-Content (Join-Path $script:Textfile 'erp__mysql-database.prom') -Raw
        $fixture=Get-Content "$script:Repo/tests/fixtures/backup-contract.json" -Raw | ConvertFrom-Json
        foreach ($property in $fixture.metricHelp.PSObject.Properties) {
            if ($metric.Contains("# HELP $($property.Name) ")) {
                $metric | Should -Match ([regex]::Escape("# HELP $($property.Name) $($property.Value)"))
                $metric | Should -Match ([regex]::Escape("# TYPE $($property.Name) gauge"))
            }
        }
        $metric | Should -Match 'producer="dbbackup"'
        $metric | Should -Match 'producer_version='
        $metric | Should -Match 'backup_last_attempt_success\{[^}]+\} 1'
        $metric | Should -Not -Match '\{(?:job|instance|host)='
    }
    It 'keeps last success after retention and a failed attempt' {
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 0
        $path=Join-Path $script:Textfile 'erp__mysql-database.prom'
        $before=Read-DBBackupMetricState $path
        $completed=Join-Path (Split-Path $script:Config) 'Completed'
        # Exact test-owned directory; emulate retention before a failed run.
        Remove-Item -LiteralPath $completed -Recurse -Force
        $env:DBBACKUP_FAKE_AGE_EXIT='1'
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 1
        (Read-DBBackupMetricState $path).LastSuccessTimestamp | Should -Be $before.LastSuccessTimestamp
        Get-Content $path -Raw | Should -Match 'backup_last_attempt_success\{[^}]+\} 0'
    }
    It 'reports degraded without advancing last successful backup' {
        $env:DBBACKUP_FAKE_MYSQLDUMP_NORMAL_EXIT='2'
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 5
        $path=Join-Path $script:Textfile 'erp__mysql-database.prom'
        (Read-DBBackupMetricState $path).LastSuccessTimestamp | Should -Be 0
        Get-Content $path -Raw | Should -Match 'backup_last_attempt_degraded\{[^}]+\} 1'
    }
    It 'does not change metrics when the instance lock is busy' {
        $c=Read-DBConfiguration $script:Config
        $runtime=New-DBRuntime $c
        try {
            Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 3
            @(Get-ChildItem $script:Textfile -File).Count | Should -Be 0
        }
        finally { Close-DBRuntime $runtime }
    }
    It 'does not create the Alloy directory and reports unavailable monitoring as an auxiliary failure' {
        Remove-Item -LiteralPath $script:Textfile
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 4
        @(Get-ChildItem (Join-Path (Split-Path $script:Config) 'Completed/database') -Directory).Count | Should -Be 1
        Test-Path $script:Textfile | Should -BeFalse
        Test-Path (Join-Path (Split-Path $script:Config) 'Runtime/Monitoring/database.json') | Should -BeTrue
    }
    It 'publishes startup failure without creating a backup' {
        Set-Content $script:Config ((Get-Content $script:Config -Raw).Replace('mysqldump.exe','missing.exe'))
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 2
        Get-Content (Join-Path $script:Textfile 'erp__mysql-database.prom') -Raw | Should -Match 'backup_last_attempt_success\{[^}]+\} 0'
    }
    It 'fails a job before native production when there is insufficient capacity' {
        Mock Assert-DBFreeSpace { throw 'Insufficient free space' } -ModuleName Runner
        $env:DBBACKUP_FAKE_INVOCATION_LOG=Join-Path $script:Root 'calls.txt'
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 1
        Get-Content $env:DBBACKUP_FAKE_INVOCATION_LOG -Raw | Should -Not -Match '--databases'
    }
    It 'keeps the first scheduled due time while there has never been a success' {
        $env:DBBACKUP_FAKE_AGE_EXIT='1'
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 1
        $path=Join-Path $script:Textfile 'erp__mysql-database.prom'
        $before=Read-DBBackupMetricState $path
        $before.SuccessDueTimestamp | Should -BeGreaterThan 0
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 1
        (Read-DBBackupMetricState $path).SuccessDueTimestamp | Should -Be $before.SuccessDueTimestamp
    }
}
