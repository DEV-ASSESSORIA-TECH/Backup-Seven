BeforeAll {
    $script:Repo=Split-Path -Parent $PSScriptRoot
    Import-Module "$script:Repo/src/Modules/Core/Runtime.psm1" -Force
    Import-Module "$script:Repo/src/Modules/Providers/SQLAnywhere/SQLAnywhere.psm1" -Force
}
Describe 'SQL Anywhere safe full-backup provider' {
    BeforeEach {
        $script:Root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null=New-Item -ItemType Directory $script:Root
        $script:Options=Join-Path $script:Root 'connection.options'
        Set-Content $script:Options '-c "UID=''backup'';PWD=''test-secret'';HOST=''192.0.2.1:2638'';DBN=''demo''"'
        $script:C=@{Database=@{Name='demo';ConnectionOptionsFile=$script:Options};Tools=@{DbBackup='dbbackup.exe';DbValid='dbvalid.exe';DbEngine='C:\Program Files\SQL Anywhere 17\Bin64\dbeng17.exe'}}
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
    It 'backs up all files without rename/truncate and validates the local copy twice' {
        $r=Invoke-DBSqlAnywhere $script:C $script:J $script:R
        $r.Status | Should -Be SUCCESS
        $r.Metadata.ProductionLogTruncate | Should -BeFalse
        Should -Invoke Invoke-DBTool -ModuleName SQLAnywhere -Times 1 -Exactly -ParameterFilter {
            $Executable -eq 'dbbackup.exe' -and $Arguments.Count -eq 2 -and $Arguments[0].StartsWith('@') -and ($Arguments -join ' ') -notmatch 'test-secret| -[rxns]'
        }
        Should -Invoke Invoke-DBTool -ModuleName SQLAnywhere -Times 2 -Exactly -ParameterFilter {
            $Executable -eq 'dbvalid.exe' -and $Arguments[0].StartsWith('@') -and ($Arguments -join ' ') -notmatch 'test-secret|192.0.2.1'
        }
        @(Get-ChildItem (Join-Path $script:R.Work '_secrets') -File).Count | Should -Be 0
    }
    It 'fails rather than publishing an unvalidated copied database' {
        Mock Invoke-DBTool { [pscustomobject]@{ExitCode=3;StdOut='';StdErr='PWD=test-secret'} } -ModuleName SQLAnywhere -ParameterFilter {$Executable -eq 'dbvalid.exe'}
        { Invoke-DBSqlAnywhere $script:C $script:J $script:R } | Should -Throw '*validation failed*'
        @(Get-ChildItem (Join-Path $script:R.Work '_secrets') -File).Count | Should -Be 0
    }
    It 'detects mutation of a copied file during validation' {
        Mock Invoke-DBTool {
            Set-Content (Join-Path $script:R.Work 'database/demo.db') 'changed'
            [pscustomobject]@{ExitCode=0;StdOut='';StdErr=''}
        } -ModuleName SQLAnywhere -ParameterFilter {$Executable -eq 'dbvalid.exe'}
        { Invoke-DBSqlAnywhere $script:C $script:J $script:R } | Should -Throw '*modified*'
    }
}
