BeforeAll {
    $script:Repo = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'V1.TestSupport.ps1')
    foreach ($name in 'Configuration','Runtime','Schedule','Artifacts','Incremental','ConfigSync') { Import-Module "$script:Repo/src/App/Modules/Core/$name.psm1" -Force }
    Import-Module "$script:Repo/src/App/Modules/Providers/SQLAnywhere/SQLAnywhere.psm1" -Force

    function New-TestBundle {
        <# A confirmed Completed bundle of job 'dominio' with the given role and times. #>
        param([string] $Root, [string] $Name, [string] $Role, [DateTime] $RecoveryPoint, [Nullable[DateTime]] $Base, [string] $RunId = ([guid]::NewGuid().ToString('N')))
        $bundle = Join-Path $Root "dominio/$Name"
        $null = New-Item -ItemType Directory $bundle -Force
        Set-Content -LiteralPath (Join-Path $bundle "$Name.7z.age") -Value 'x' -NoNewline
        $state = @{ SchemaVersion = 1; Instance = 'acme'; Job = 'dominio'; RunId = $RunId; Role = $Role; LocalStatus = 'SUCCESS'
            RecoveryPointUtc = $RecoveryPoint.ToUniversalTime().ToString('o'); FileName = "$Name.7z.age"; SizeBytes = 1; Sha256 = 'x'
            RemotePath = "s3:b/dominio/$Name.7z.age"; Transport = 'CONFIRMED' }
        if ($null -ne $Base) { $state.BaseRecoveryPointUtc = ([DateTime] $Base).ToUniversalTime().ToString('o') }
        $state | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $bundle 'state.json')
        return $bundle
    }
}

Describe 'Server environment (ambiente.psd1)' {
    It 'merges built-in, environment and instance values in that order and derives dbbackup from the SQL Anywhere folder' {
        $environment = @{ SchemaVersion = 1; Tools = @{ SevenZip = 'C:\env\7z.exe'; SqlAnywhere = 'C:\Program Files\SQL Anywhere 17\Tools' }
            Retention = @{ CompletedDays = 10 }; Monitoring = @{ TextfileDirectory = 'C:\alloy' } }
        $configuration = @{ Tools = @{ SevenZip = 'C:\instance\7z.exe' }; Monitoring = @{ Enabled = $false } }
        Merge-DBEnvironment $configuration $environment
        $configuration.Tools.SevenZip | Should -Be 'C:\instance\7z.exe'
        $configuration.Tools.DbBackup | Should -Be (Join-Path 'C:\Program Files\SQL Anywhere 17\Tools' 'dbbackup.exe')
        $configuration.Tools.Contains('SqlAnywhere') | Should -BeFalse
        $configuration.Retention.CompletedDays | Should -Be 10
        $configuration.Retention.LogDays | Should -Be 30
        $configuration.Archive.CompressionLevel | Should -Be 5
        $configuration.Monitoring.TextfileDirectory | Should -Be 'C:\alloy'
    }
    It 'reads an instance without Tools when the environment beside Instances has them' {
        $root = Join-Path $TestDrive 'env'
        $instance = Join-Path $root 'Instances/acme'
        $null = New-Item -ItemType Directory (Join-Path $instance 'Secrets') -Force
        $text = (Get-DBTestConfigText -InstanceName 'acme' -RemoteRoot 's3:bucket/ACME') -replace '(?s)    Tools = @\{.*?\n    \}\n', ''
        Set-Content (Join-Path $instance 'config.psd1') $text
        Set-Content (Join-Path $root 'ambiente.psd1') "@{ SchemaVersion = 1; Tools = @{ Rclone = 'C:\env\rclone.exe'; SevenZip = 'C:\env\7z.exe'; Age = 'C:\env\age.exe'; MySql = 'C:\env\mysql.exe'; MySqlDump = 'C:\env\mysqldump.exe' } }"
        $c = Read-DBConfiguration (Join-Path $instance 'config.psd1')
        $c.Tools.Rclone | Should -Match 'rclone\.exe$'
        $c.EnvironmentPath | Should -Be (Join-Path $root 'ambiente.psd1')
    }
}

Describe 'Incremental schedule' {
    BeforeAll {
        $script:Config = @{ InstanceName = 'acme'
            Jobs = @([pscustomobject]@{ Id = 'dominio'; Incremental = $true }, [pscustomobject]@{ Id = 'seven'; Incremental = $false })
            Schedule = @{ Tasks = @(
                @{ Name = 'completo'; Jobs = @('dominio','seven'); At = '19:00' }
                @{ Name = 'incremental'; Jobs = @('dominio'); At = @('09:00','12:00','15:00','18:00'); Mode = 'Incremental' }) } }
    }
    It 'passes -Mode Incremental to the task and computes the next run per mode' {
        $tasks = @(Get-DBScheduleTask $script:Config)
        $tasks[1].Mode | Should -Be 'Incremental'
        $definition = Get-DBTaskDefinition -Task $tasks[1] -PwshPath 'pwsh.exe' -ScriptPath 'C:\DBBackup\App\Backup.ps1' -WorkingDirectory 'C:\DBBackup' -ConfigPath 'C:\DBBackup\Instances\acme\config.psd1'
        $definition.Arguments | Should -Match '-Job dominio -Mode Incremental$'
        (Get-DBTaskDefinition -Task $tasks[0] -PwshPath 'pwsh.exe' -ScriptPath 'b.ps1' -WorkingDirectory 'C:\' -ConfigPath 'c.psd1').Arguments | Should -Not -Match 'Mode'
        $after = [DateTime]::new(2026, 11, 19, 12, 30, 0)
        Get-DBScheduleNextRun -Tasks $tasks -Job 'dominio' -After $after -Mode Incremental | Should -Be ([DateTime]::new(2026, 11, 19, 15, 0, 0))
        Get-DBScheduleNextRun -Tasks $tasks -Job 'dominio' -After $after | Should -Be ([DateTime]::new(2026, 11, 19, 19, 0, 0))
    }
    It 'refuses an incremental task for a job without Incremental.Enabled' {
        $bad = @{ InstanceName = 'acme'; Jobs = $script:Config.Jobs; Schedule = @{ Tasks = @(@{ Name = 'inc'; Jobs = @('seven'); At = '09:00'; Mode = 'Incremental' }) } }
        { Get-DBScheduleTask $bad } | Should -Throw '*Incremental.Enabled*'
    }
}

Describe 'SQL Anywhere incremental provider' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory $script:Root
        $options = Join-Path $script:Root 'connection.options'
        Set-Content $options '-c "UID=''backup'';PWD=''test-secret'';SERVER=''srv'';DBN=''demo''"'
        $script:C = @{ Tools = @{ DbBackup = 'dbbackup.exe' } }
        $script:R = [pscustomobject]@{ RunId = 'r1'; Work = (Join-Path $script:Root 'work') }
        $script:J = [pscustomobject]@{ Id = 'dominio'; Provider = 'SQLAnywhere'; Database = 'demo'; CredentialFile = $options; Incremental = $true }
        Mock Set-Acl {} -ModuleName Runtime
        Mock Invoke-DBTool {
            param($Executable, $Arguments)
            if ($Executable -eq 'dbbackup.exe') {
                if ($Arguments -notcontains '-t') { Set-Content (Join-Path $Arguments[-1] 'demo.db') 'db' }
                Set-Content (Join-Path $Arguments[-1] 'demo.log') 'log'
            }
            [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
        } -ModuleName SQLAnywhere
    }
    It 'renames the production log (-r) on the full of an incremental job' {
        $r = Invoke-DBSqlAnywhere $script:C $script:J $script:R
        $r.Packages[0].Role | Should -Be 'FULL'
        $r.Metadata.ProductionLogRename | Should -BeTrue
        Should -Invoke Invoke-DBTool -ModuleName SQLAnywhere -Times 1 -Exactly -ParameterFilter { $Executable -eq 'dbbackup.exe' -and $Arguments[1] -eq '-r' -and $Arguments -notcontains '-x' }
    }
    It 'copies only the current log (-t) since the base on an incremental' {
        $base = [pscustomobject]@{ BaseRunId = 'base1'; BaseRecoveryPointUtc = '2026-11-18T22:00:00.0000000Z' }
        $r = Invoke-DBSqlAnywhere $script:C $script:J $script:R -Mode Incremental -Base $base
        $r.Packages[0].Role | Should -Be 'INCREMENTAL'
        $r.Metadata.BaseRunId | Should -Be 'base1'
        $r.Metadata.LogFiles | Should -Be @('demo.log')
        Should -Invoke Invoke-DBTool -ModuleName SQLAnywhere -Times 1 -Exactly -ParameterFilter { $Executable -eq 'dbbackup.exe' -and $Arguments[1] -eq '-t' -and $Arguments -notcontains '-r' }
    }
    It 'refuses an incremental without a base' {
        { Invoke-DBSqlAnywhere $script:C $script:J $script:R -Mode Incremental } | Should -Throw '*base*'
    }
}

Describe 'Incremental retention and renamed logs' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $completed = Join-Path $script:Root 'Completed'
        $logs = Join-Path $script:Root 'Logs'
        $null = New-Item -ItemType Directory $completed, $logs, (Join-Path $script:Root 'Runtime') -Force
        $script:C = @{ InstanceName = 'acme'; Jobs = @([pscustomobject]@{ Id = 'dominio'; KeepRenamedLogDays = 3 })
            Retention = @{ CompletedDays = 7; LogDays = 30 }
            Paths = @{ CompletedRoot = $completed; LogRoot = $logs; RuntimeRoot = (Join-Path $script:Root 'Runtime') } }
        $script:R = [pscustomobject]@{ Completed = $completed; LogPath = (Join-Path $logs 'run.log') }
        Mock Set-Acl {} -ModuleName Runtime
    }
    It 'drops incrementals whose base is older than the previous full and keeps the last day' {
        $now = [DateTime]::UtcNow
        $full2 = $now.AddDays(-2); $full1 = $now.AddDays(-1); $full0 = $now.AddHours(-1)
        foreach ($f in @(@('f2', $full2), @('f1', $full1), @('f0', $full0))) { $null = New-TestBundle $script:C.Paths.CompletedRoot $f[0] 'FULL' $f[1] $null }
        $old = New-TestBundle $script:C.Paths.CompletedRoot 'i-old' 'INCREMENTAL' $full2.AddHours(4) $full2
        $kept = New-TestBundle $script:C.Paths.CompletedRoot 'i-kept' 'INCREMENTAL' $full1.AddHours(4) $full1
        Remove-DBExpired -Configuration $script:C -Runtime $script:R
        $old | Should -Not -Exist
        $kept | Should -Exist
        @(Get-ChildItem (Join-Path $script:C.Paths.CompletedRoot 'dominio') -Directory).Count | Should -Be 4
    }
    It 'removes nothing new when only one full exists' {
        $now = [DateTime]::UtcNow
        $null = New-TestBundle $script:C.Paths.CompletedRoot 'f0' 'FULL' $now.AddDays(-1) $null
        $inc = New-TestBundle $script:C.Paths.CompletedRoot 'i0' 'INCREMENTAL' $now $now.AddDays(-2)
        Remove-DBExpired -Configuration $script:C -Runtime $script:R
        $inc | Should -Exist
    }
    It 'removes renamed production logs only after the base full is confirmed and older than the limit' {
        $dbFolder = Join-Path $script:Root 'Dados'
        $null = New-Item -ItemType Directory $dbFolder
        foreach ($name in '261110AA.log', '261118AB.log', 'contabil.log') { Set-Content (Join-Path $dbFolder $name) 'x' }
        (Get-Item (Join-Path $dbFolder '261110AA.log')).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-9)
        (Get-Item (Join-Path $dbFolder 'contabil.log')).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-9)
        $baseTime = [DateTime]::UtcNow.AddHours(-2)
        Save-DBIncrementalBase -Configuration $script:C -Job 'dominio' -RunId 'base1' -RecoveryPointUtc $baseTime -LogDirectory $dbFolder
        @(Remove-DBRenamedLog -Configuration $script:C -Job $script:C.Jobs[0]).Count | Should -Be 0
        $null = New-TestBundle $script:C.Paths.CompletedRoot 'base' 'FULL' $baseTime $null -RunId 'base1'
        @(Remove-DBRenamedLog -Configuration $script:C -Job $script:C.Jobs[0]) | Should -Be @('261110AA.log')
        Join-Path $dbFolder '261118AB.log' | Should -Exist
        Join-Path $dbFolder 'contabil.log' | Should -Exist
    }
}

Describe 'Versioned configurations' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $instance = Join-Path $script:Root 'Instances/acme'
        $null = New-Item -ItemType Directory (Join-Path $instance 'Secrets') -Force
        Set-Content (Join-Path $instance 'config.psd1') (Get-DBTestConfigText -InstanceName 'acme' -RemoteRoot 's3:bucket/ACME')
        Set-Content (Join-Path $script:Root 'ambiente.psd1') "@{ SchemaVersion = 1 }"
    }
    It 'exports ambiente.psd1 and the instance configs but never Secrets' {
        Set-Content (Join-Path $script:Root 'Instances/acme/Secrets/rclone.conf') 'secret_access_key = x'
        $result = Export-DBVersionedConfiguration -InstallRoot $script:Root -Destination (Join-Path $script:Root 'out') -ServerName 'srv-a'
        @($result.Files) | Should -Be @('ambiente.psd1', 'acme/config.psd1')
        @(Get-ChildItem (Join-Path $script:Root 'out') -Recurse -File).Name | Should -Not -Contain 'rclone.conf'
        { Assert-DBNoSecretText "-c `"UID=a;PWD=b`"" 'x' } | Should -Throw '*segredo*'
    }
    It 'installs changed files keeping .anterior and rolls everything back when one is invalid' {
        $config = Join-Path $script:Root 'Instances/acme/config.psd1'
        $original = Get-Content $config -Raw
        $changed = $original.Replace("CompletedDays = 7", "CompletedDays = 9")
        $changes = @(Compare-DBVersionedFile -InstallRoot $script:Root -Remote @([pscustomobject]@{ Relative = 'acme/config.psd1'; Text = $changed }))
        $changes.Count | Should -Be 1
        ($changes[0].Diff -join "`n") | Should -Match 'CompletedDays = 9'
        Install-DBVersionedFile -InstallRoot $script:Root -Changes $changes | Should -Be 'acme'
        (Get-Content $config -Raw) | Should -Match 'CompletedDays = 9'
        "$config.anterior" | Should -Exist
        $bad = @(Compare-DBVersionedFile -InstallRoot $script:Root -Remote @(
            [pscustomobject]@{ Relative = 'acme/config.psd1'; Text = $original }
            [pscustomobject]@{ Relative = 'ambiente.psd1'; Text = '@{ SchemaVersion = 99 }' }))
        { Install-DBVersionedFile -InstallRoot $script:Root -Changes $bad } | Should -Throw '*nada foi alterado*'
        (Get-Content $config -Raw) | Should -Match 'CompletedDays = 9'
        (Get-Content (Join-Path $script:Root 'ambiente.psd1') -Raw).Trim() | Should -Be '@{ SchemaVersion = 1 }'
    }
    It 'accepts only ambiente.psd1 and instance config.psd1 files' {
        { Get-DBVersionedLocalPath $script:Root 'acme/Secrets/rclone.conf' } | Should -Throw
        { Get-DBVersionedLocalPath $script:Root '../x/config.psd1' } | Should -Throw
    }
}
