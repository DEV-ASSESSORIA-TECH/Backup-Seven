BeforeAll {
    $script:Repo=Split-Path -Parent $PSScriptRoot
    Import-Module "$script:Repo/src/Modules/Core/Runtime.psm1"
    Import-Module "$script:Repo/src/Modules/Providers/SQLAnywhere/SQLAnywhere.psm1"
}
Describe 'SQL Anywhere safe full-backup provider' {
    BeforeEach {
        $script:Root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $null=New-Item -ItemType Directory $script:Root
        $script:Options=Join-Path $script:Root 'connection.options'
        Set-Content $script:Options '-c "UID=''backup'';PWD=''test-secret'';HOST=''192.0.2.1:2638'';DBN=''demo''"'
        $script:C=@{Database=@{Name='demo';ConnectionOptionsFile=$script:Options};Tools=@{DbBackup='dbbackup.exe'}}
        $script:R=[pscustomobject]@{RunId='0123456789abcdef0123456789abcdef';Work=(Join-Path $script:Root 'work')}
        $script:J=[pscustomobject]@{Id='database'}
        Mock Set-Acl {} -ModuleName Runtime
        Mock Invoke-DBTool {
            param($Executable,$Arguments)
            if ($Executable -eq 'dbbackup.exe') {
                Set-Content (Join-Path $Arguments[-1] 'demo.db') 'fake database'
                Set-Content (Join-Path $Arguments[-1] 'demo.log') 'fake log'
            }
            [pscustomobject]@{ExitCode=0;StdOut='';StdErr=''}
        } -ModuleName SQLAnywhere
    }
    It 'only accepts a single connection option and rejects log-control flags' {
        Add-Content $script:Options '-x'
        { Read-DBSqlConnection $script:Options } | Should -Throw '*exactly*'
    }
    It 'rejects DSN and arbitrary startup parameters in the production connection' {
        Set-Content $script:Options '-c "UID=u;PWD=p;HOST=h;DBN=demo;START=dangerous"'
        { Read-DBSqlConnection $script:Options } | Should -Throw '*Unsupported*'
    }
    It 'backs up without log-control flags or starting validation/restore engines' {
        $r=Invoke-DBSqlAnywhere $script:C $script:J $script:R
        $r.Status | Should -Be SUCCESS
        $r.Metadata.RecoveryValidation | Should -Be 'external-not-performed'
        Should -Invoke Invoke-DBTool -ModuleName SQLAnywhere -Times 1 -Exactly -ParameterFilter {
            $Executable -eq 'dbbackup.exe' -and $Arguments.Count -eq 2 -and $Arguments[0].StartsWith('@') -and ($Arguments -join ' ') -notmatch 'test-secret| -[rxns]'
        }
        Should -Invoke Invoke-DBTool -ModuleName SQLAnywhere -Times 0 -Exactly -ParameterFilter { $Executable -match 'dbvalid|dbeng|dbsrv' }
        Test-Path (Join-Path $script:R.Work '_secrets') | Should -BeFalse
    }
    It 'rejects an empty database or transaction log file' {
        Mock Invoke-DBTool {
            param($Arguments)
            Set-Content (Join-Path $Arguments[-1] 'demo.db') 'database'
            [IO.File]::WriteAllBytes((Join-Path $Arguments[-1] 'demo.log'), [byte[]]@())
            [pscustomobject]@{ExitCode=0;StdOut='';StdErr=''}
        } -ModuleName SQLAnywhere
        { Invoke-DBSqlAnywhere $script:C $script:J $script:R } | Should -Throw '*empty*'
    }
    It 'fails on a native backup error with redacted diagnostics and removes transient credentials' {
        Mock Invoke-DBTool { [pscustomobject]@{ExitCode=3;StdOut='Database server not found';StdErr='PWD=test-secret; echoed test-secret'} } -ModuleName SQLAnywhere
        $message = $null
        try { Invoke-DBSqlAnywhere $script:C $script:J $script:R } catch { $message = $_.Exception.Message }
        $message | Should -BeLike '*backup failed*'
        $message | Should -Match 'Database server not found'
        $message | Should -Not -Match 'test-secret'
        Test-Path (Join-Path $script:R.Work '_secrets') | Should -BeFalse
    }
    It 'accepts a local SERVER connection without HOST and requires one of them' {
        Set-Content $script:Options '-c "UID=u;PWD=p;SERVER=demo_srv;DBN=demo"'
        (Read-DBSqlConnection $script:Options).SERVER | Should -Be 'demo_srv'
        Set-Content $script:Options '-c "UID=u;PWD=p;DBN=demo"'
        { Read-DBSqlConnection $script:Options } | Should -Throw '*HOST or SERVER*'
    }
    It 'accepts databases with additional dbspace files' {
        Mock Invoke-DBTool {
            param($Arguments)
            foreach ($name in @('demo.db','demo_space2.db','demo.log')) { Set-Content (Join-Path $Arguments[-1] $name) 'fake' }
            [pscustomobject]@{ExitCode=0;StdOut='';StdErr=''}
        } -ModuleName SQLAnywhere
        $r = Invoke-DBSqlAnywhere $script:C $script:J $script:R
        $r.Status | Should -Be SUCCESS
        @($r.Metadata.DatabaseFiles).Count | Should -Be 2
    }
}
