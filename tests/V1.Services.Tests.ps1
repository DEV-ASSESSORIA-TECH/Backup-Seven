Describe 'DBBackup module contracts' {
BeforeAll {
    $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("DBBackup-modules-$([guid]::NewGuid().ToString('N'))")
    $null = New-Item -ItemType Directory -Path $script:TestRoot
    $fakeTool = Join-Path $script:TestRoot 'fake-tool.exe'
    $compiler = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $compiler '/nologo' '/target:exe' "/out:$fakeTool" (Join-Path $PSScriptRoot 'fixtures/V1FakeTool.cs')
    if ($LASTEXITCODE -ne 0) {
        throw "Fake tool compilation failed with exit code $LASTEXITCODE."
    }

    $script:SevenZip = Join-Path $script:TestRoot '7z.exe'
    $script:MySqlDump = Join-Path $script:TestRoot 'mysqldump.exe'
    $script:MySql = Join-Path $script:TestRoot 'mysql.exe'
    $script:Rclone = Join-Path $script:TestRoot 'rclone.exe'
    $script:InvocationLog = Join-Path $script:TestRoot 'tool-invocations.log'
    $env:DBBACKUP_FAKE_INVOCATION_LOG = $script:InvocationLog
    Copy-Item $fakeTool $script:SevenZip
    Copy-Item $fakeTool $script:MySqlDump
    Copy-Item $fakeTool $script:MySql
    Copy-Item $fakeTool $script:Rclone

    $script:DefaultsFile = Join-Path $script:TestRoot 'mysql.cnf'
    $script:RcloneConfig = Join-Path $script:TestRoot 'rclone.conf'
    Set-Content -LiteralPath $script:DefaultsFile -Value "[client]`nuser=test"
    Set-Content -LiteralPath $script:RcloneConfig -Value "[s3]`ntype=s3"

    Import-Module (Join-Path $PSScriptRoot '../src/Modules/Core/Archive.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../src/Modules/Providers/MySQL/Client.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../src/Modules/Core/Storage.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../src/Modules/Core/Monitoring.psm1') -Force
}

AfterAll {
    foreach ($name in @(
        'DBBACKUP_FAKE_7ZIP_CREATE_EXIT',
        'DBBACKUP_FAKE_7ZIP_TEST_EXIT',
        'DBBACKUP_FAKE_RCLONE_LIST_EXIT',
        'DBBACKUP_FAKE_RCLONE_COPY_EXIT',
        'DBBACKUP_FAKE_RCLONE_CHECK_EXIT',
        'DBBACKUP_FAKE_RCLONE_FAIL_MATCH',
        'DBBACKUP_FAKE_MYSQLDUMP_EXIT',
        'DBBACKUP_FAKE_MYSQLDUMP_NORMAL_EXIT',
        'DBBACKUP_FAKE_MYSQLDUMP_FORCE_EXIT',
        'DBBACKUP_FAKE_MYSQLDUMP_FAILED_OBJECT',
        'DBBACKUP_FAKE_MYSQL_EXIT',
        'DBBACKUP_FAKE_MYSQL_OBJECTS',
        'DBBACKUP_FAKE_INVOCATION_LOG'
    )) {
        [Environment]::SetEnvironmentVariable($name, $null)
    }

    if (Test-Path -LiteralPath $script:TestRoot) {
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force
    }
}

Context 'Archive module' {
    It 'creates and validates a non-empty archive' {
        $source = Join-Path $script:TestRoot 'source.txt'
        $archive = Join-Path $script:TestRoot 'successful.7z'
        Set-Content -LiteralPath $source -Value 'content'

        $result = New-DBArchive -SevenZipPath $script:SevenZip -SourcePath $source -ArchivePath $archive

        $result.Length | Should -BeGreaterThan 0
        Test-Path -LiteralPath $archive | Should -BeTrue
    }

    It 'limits 7-Zip threads from the configured CPU percentage' {
        $source = Join-Path $script:TestRoot 'cpu-source.txt'
        $archive = Join-Path $script:TestRoot 'cpu-limited.7z'
        Set-Content -LiteralPath $source -Value 'content'
        $expectedThreads = [Math]::Max(1, [Math]::Floor([Environment]::ProcessorCount * 0.5))

        $null = New-DBArchive `
            -SevenZipPath $script:SevenZip `
            -SourcePath $source `
            -ArchivePath $archive `
            -CpuLimitPercent 50

        Get-Content -LiteralPath $script:InvocationLog -Raw |
            Should -Match "\|-mmt=$expectedThreads\|"
    }

    It 'rejects warnings and removes the invalid archive' {
        $source = Join-Path $script:TestRoot 'warning-source.txt'
        $archive = Join-Path $script:TestRoot 'warning.7z'
        Set-Content -LiteralPath $source -Value 'content'
        $env:DBBACKUP_FAKE_7ZIP_CREATE_EXIT = '1'

        { New-DBArchive -SevenZipPath $script:SevenZip -SourcePath $source -ArchivePath $archive } |
            Should -Throw '*exit code 1*'
        Test-Path -LiteralPath $archive | Should -BeFalse

        $env:DBBACKUP_FAKE_7ZIP_CREATE_EXIT = $null
    }

    It 'removes an archive that fails the integrity test' {
        $source = Join-Path $script:TestRoot 'invalid-source.txt'
        $archive = Join-Path $script:TestRoot 'invalid.7z'
        Set-Content -LiteralPath $source -Value 'content'
        $env:DBBACKUP_FAKE_7ZIP_TEST_EXIT = '2'

        { New-DBArchive -SevenZipPath $script:SevenZip -SourcePath $source -ArchivePath $archive } |
            Should -Throw '*validation failed*'
        Test-Path -LiteralPath $archive | Should -BeFalse

        $env:DBBACKUP_FAKE_7ZIP_TEST_EXIT = $null
    }

    It 'archives directory contents without the staging directory name' {
        $source = Join-Path $script:TestRoot 'manifest-source'
        $archive = Join-Path $script:TestRoot 'contents.7z'
        $null = New-Item -ItemType Directory -Path $source
        Set-Content -LiteralPath (Join-Path $source 'manifest.json') -Value '{"status":"SUCCESS"}'

        $null = New-DBArchive -SevenZipPath $script:SevenZip -SourcePath $source -ArchivePath $archive -ContentsOnly

        Get-Content -LiteralPath $archive -Raw | Should -Match 'ENTRY:manifest\.json'
    }
}

Context 'Database module' {
    It 'streams a non-empty database dump to disk' {
        $dump = Join-Path $script:TestRoot 'database.sql'

        $result = New-MySqlDatabaseDump `
            -MySqlDumpPath $script:MySqlDump `
            -DefaultsExtraFile $script:DefaultsFile `
            -DatabaseName seven `
            -OutputPath $dump

        $result.Length | Should -BeGreaterThan 0
        Get-Content -LiteralPath $dump -Raw | Should -Match 'CREATE DATABASE'
    }

    It 'rejects passwords in extra arguments' {
        $dump = Join-Path $script:TestRoot 'password.sql'

        { New-MySqlDatabaseDump `
                -MySqlDumpPath $script:MySqlDump `
                -DefaultsExtraFile $script:DefaultsFile `
                -DatabaseName seven `
                -OutputPath $dump `
                -ExtraArguments '--password=secret' } | Should -Throw '*must not contain a password*'
    }

    It 'rejects force in extra arguments' {
        $dump = Join-Path $script:TestRoot 'force.sql'

        { New-MySqlDatabaseDump `
                -MySqlDumpPath $script:MySqlDump `
                -DefaultsExtraFile $script:DefaultsFile `
                -DatabaseName seven `
                -OutputPath $dump `
                -ExtraArguments '--force' } | Should -Throw '*must not contain --force*'
    }

    It 'lists base tables and views' {
        $objects = @(Get-MySqlDatabaseObject `
                -MySqlPath $script:MySql `
                -DefaultsExtraFile $script:DefaultsFile `
                -DatabaseName seven)

        $objects.Count | Should -Be 3
        $objects[0].Name | Should -Be 'clientes'
        $objects[2].ObjectType | Should -Be 'VIEW'
    }

    It 'preserves a non-empty forced dump with a non-zero exit code' {
        $dump = Join-Path $script:TestRoot 'degraded.sql'
        $env:DBBACKUP_FAKE_MYSQLDUMP_FORCE_EXIT = '2'

        $result = Invoke-MySqlDatabaseDump `
            -MySqlDumpPath $script:MySqlDump `
            -DefaultsExtraFile $script:DefaultsFile `
            -DatabaseName seven `
            -OutputPath $dump `
            -Force

        $result.ExitCode | Should -Be 2
        $result.IsNonEmpty | Should -BeTrue
        Test-Path -LiteralPath $dump | Should -BeTrue
        $env:DBBACKUP_FAKE_MYSQLDUMP_FORCE_EXIT = $null
    }

    It 'normalizes unsafe and colliding object file names' {
        $used = @{}

        Get-MySqlSafeFileName -Name 'sales:2026' -UsedNames $used |
            Should -Match '^sales_2026_[a-f0-9]{8}$'
        Get-MySqlSafeFileName -Name 'clientes' -UsedNames $used | Should -Be 'clientes'
        Get-MySqlSafeFileName -Name 'CLIENTES' -UsedNames $used |
            Should -Match '^CLIENTES_[a-f0-9]{8}$'
    }
}

Context 'Storage module' {
    It 'finds the configured remote and validates an uploaded file' {
        $archive = Join-Path $script:TestRoot 'upload.7z'
        Set-Content -LiteralPath $archive -Value 'archive'

        Test-DBStorageConfiguration `
            -RclonePath $script:Rclone `
            -ConfigPath $script:RcloneConfig `
            -RemoteRoot 's3:bucket/backups' | Should -BeTrue

        Send-DBBackupFile `
            -RclonePath $script:Rclone `
            -ConfigPath $script:RcloneConfig `
            -LocalPath $archive `
            -RemotePath 's3:bucket/backups/upload.7z' | Should -Be 's3:bucket/backups/upload.7z'
    }

    It 'fails when remote validation fails' {
        $archive = Join-Path $script:TestRoot 'failed-check.7z'
        Set-Content -LiteralPath $archive -Value 'archive'
        $env:DBBACKUP_FAKE_RCLONE_CHECK_EXIT = '1'

        { Send-DBBackupFile `
                -RclonePath $script:Rclone `
                -ConfigPath $script:RcloneConfig `
                -LocalPath $archive `
                -RemotePath 's3:bucket/backups/failed-check.7z' } | Should -Throw '*rclone check failed*'

        $env:DBBACKUP_FAKE_RCLONE_CHECK_EXIT = $null
    }
}

Context 'Monitoring module' {
    It 'formats the generic backup contract with fixed identity labels' {
        $content = Format-DBBackupMetric `
            -Service 'seven' `
            -BackupId 'database' `
            -CollectedAtUtc ([DateTime]::new(2026, 11, 13, 12, 0, 0, [DateTimeKind]::Utc)) `
            -CollectionSucceeded $true `
            -AttemptFinishedAtUtc ([DateTime]::new(2026, 11, 13, 12, 0, 0, [DateTimeKind]::Utc)) `
            -AttemptSucceeded $true `
            -AttemptDegraded $false `
            -AttemptDurationSeconds 184.1234 `
            -LastSuccessTimestamp 1794592800 `
            -LastSuccessSizeBytes 524288000 `
            -ExpectedIntervalSeconds 61200 `
            -InfoLabels ([ordered]@{ kind = 'database'; site = 'multi "copias"' })

        $content | Should -Not -Match "`r"
        $content | Should -Match "`n$"
        $content | Should -Match '(?m)^# TYPE backup_last_success_timestamp_seconds gauge$'
        $content | Should -Match '(?m)^backup_last_success_timestamp_seconds\{service="seven",backup_id="database"\} 1794592800$'
        $content | Should -Match '(?m)^backup_last_success_size_bytes\{service="seven",backup_id="database"\} 524288000$'
        $content | Should -Match '(?m)^backup_last_attempt_timestamp_seconds\{service="seven",backup_id="database"\} 1794571200$'
        $content | Should -Match '(?m)^backup_last_attempt_success\{service="seven",backup_id="database"\} 1$'
        $content | Should -Match '(?m)^backup_last_attempt_duration_seconds\{service="seven",backup_id="database"\} 184\.123$'
        $content | Should -Match '(?m)^backup_last_attempt_degraded\{service="seven",backup_id="database"\} 0$'
        $content | Should -Match '(?m)^backup_expected_interval_seconds\{service="seven",backup_id="database"\} 61200$'
        $content | Should -Match '(?m)^backup_collection_success\{service="seven",backup_id="database"\} 1$'
        $content | Should -Match '(?m)^backup_info\{service="seven",backup_id="database",kind="database",site="multi \\"copias\\""\} 1$'
        $content | Should -Not -Match '(?m)^[a-z_]+\{[^}]*(job|instance|host)='
    }

    It 'publishes and reads back the success due time' {
        $directory = Join-Path $script:TestRoot 'textfile-due'
        $null = New-Item -ItemType Directory -Path $directory -Force
        $content = Format-DBBackupMetric `
            -Service 'seven' `
            -BackupId 'fiscal' `
            -CollectedAtUtc ([DateTime]::UtcNow) `
            -CollectionSucceeded $true `
            -SuccessDueTimestamp 1794700800 `
            -InfoLabels ([ordered]@{ criticality = 'baixa' })

        $content | Should -Match '(?m)^# TYPE backup_success_due_timestamp_seconds gauge$'
        $content | Should -Match '(?m)^backup_success_due_timestamp_seconds\{service="seven",backup_id="fiscal"\} 1794700800$'
        $content | Should -Match 'criticality="baixa"'
        $path = Write-DBBackupMetric -Directory $directory -Service 'seven' -BackupId 'fiscal' -Content $content
        (Read-DBBackupMetricState -Path $path).SuccessDueTimestamp | Should -Be 1794700800
    }

    It 'omits state that is not known' {
        $content = Format-DBBackupMetric `
            -Service 'seven' `
            -BackupId 'fiscal' `
            -CollectedAtUtc ([DateTime]::UtcNow) `
            -CollectionSucceeded $false

        $content | Should -Match '(?m)^backup_collection_success\{service="seven",backup_id="fiscal"\} 0$'
        $content | Should -Not -Match 'backup_last_'
        $content | Should -Not -Match 'backup_expected_interval_seconds'
    }

    It 'rejects identifiers outside the contract' {
        { Format-DBBackupMetric -Service 'Seven' -BackupId 'database' -CollectedAtUtc ([DateTime]::UtcNow) -CollectionSucceeded $true } |
            Should -Throw '*service identifier*'
        { Format-DBBackupMetric -Service 'seven' -BackupId 'a__b' -CollectedAtUtc ([DateTime]::UtcNow) -CollectionSucceeded $true } |
            Should -Throw '*backup identifier*'
        { Format-DBBackupMetric -Service 'seven' -BackupId 'database' -CollectedAtUtc ([DateTime]::UtcNow) -CollectionSucceeded $true -InfoLabels @{ instance = 'x' } } |
            Should -Throw '*backup_info label*'
    }

    It 'writes atomically and reads the last success back' {
        $directory = Join-Path $script:TestRoot 'textfile'
        $null = New-Item -ItemType Directory -Path $directory -Force
        $content = Format-DBBackupMetric `
            -Service 'seven' `
            -BackupId 'database' `
            -CollectedAtUtc ([DateTime]::UtcNow) `
            -CollectionSucceeded $true `
            -LastSuccessTimestamp 1794592800 `
            -LastSuccessSizeBytes 42

        $path = Write-DBBackupMetric -Directory $directory -Service 'seven' -BackupId 'database' -Content $content

        $path | Should -Be (Join-Path $directory 'seven__database.prom')
        Test-Path -LiteralPath "$path.tmp" | Should -BeFalse
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $bytes[0] | Should -Be ([byte][char]'#')
        $state = Read-DBBackupMetricState -Path $path
        $state.LastSuccessTimestamp | Should -Be 1794592800
        $state.LastSuccessSizeBytes | Should -Be 42
        (Read-DBBackupMetricState -Path (Join-Path $directory 'missing.prom')).LastSuccessTimestamp | Should -Be 0
    }

    It 'never creates the textfile directory' {
        $missing = Join-Path $script:TestRoot 'missing-textfile'
        { Write-DBBackupMetric -Directory $missing -Service 'seven' -BackupId 'database' -Content "x`n" } |
            Should -Throw '*directory was not found*'
        Test-Path -LiteralPath $missing | Should -BeFalse
    }
}
}
