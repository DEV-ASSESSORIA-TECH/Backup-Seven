Describe 'BackupSeven application' {
BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:EntryScript = Join-Path $script:RepositoryRoot 'src/Backup-Seven.ps1'
    $script:FixtureSource = Join-Path $PSScriptRoot 'fixtures/FakeExternalTool.cs'
    $script:PwshPath = (Get-Command pwsh).Source

    function Invoke-TestBackup([string] $Mode) {
        $script:LastBackupOutput = @(& $script:PwshPath `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -File $script:EntryScript `
            -Mode $Mode `
            -ConfigPath $script:ConfigPath 2>&1)

        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0 -and (Test-Path -LiteralPath $script:Logs)) {
            $logLines = @(Get-ChildItem -LiteralPath $script:Logs -Filter '*.log' -File |
                    ForEach-Object { Get-Content -LiteralPath $_.FullName })
            $script:LastBackupOutput += $logLines
        }

        return $exitCode
    }
}

BeforeEach {
    $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("BackupSeven-integration-$([guid]::NewGuid().ToString('N'))")
    $tools = Join-Path $script:TestRoot 'tools'
    $fiscal = Join-Path $script:TestRoot 'Fiscal'
    $secrets = Join-Path $script:TestRoot 'secrets'
    $script:Runtime = Join-Path $script:TestRoot 'Runtime'
    $script:Completed = Join-Path $script:TestRoot 'Completed'
    $script:Logs = Join-Path $script:TestRoot 'Logs'
    $script:InvocationLog = Join-Path $script:TestRoot 'tool-invocations.log'
    $env:BACKUPSEVEN_FAKE_INVOCATION_LOG = $script:InvocationLog
    $null = New-Item -ItemType Directory -Path $tools, $fiscal, $secrets -Force
    Set-Content -LiteralPath (Join-Path $fiscal 'fiscal.txt') -Value 'fiscal content'

    $fakeTool = Join-Path $tools 'fake-tool.exe'
    $compiler = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $compiler '/nologo' '/target:exe' "/out:$fakeTool" $script:FixtureSource
    if ($LASTEXITCODE -ne 0) {
        throw "Fake tool compilation failed with exit code $LASTEXITCODE."
    }
    $script:SevenZip = Join-Path $tools '7z.exe'
    $script:MySqlDump = Join-Path $tools 'mysqldump.exe'
    $script:MySql = Join-Path $tools 'mysql.exe'
    $script:Rclone = Join-Path $tools 'rclone.exe'
    Copy-Item $fakeTool $script:SevenZip
    Copy-Item $fakeTool $script:MySqlDump
    Copy-Item $fakeTool $script:MySql
    Copy-Item $fakeTool $script:Rclone

    $script:DefaultsFile = Join-Path $secrets 'mysql.cnf'
    $rcloneConfig = Join-Path $secrets 'rclone.conf'
    Set-Content -LiteralPath $script:DefaultsFile -Value "[client]`nuser=test`npassword=super-secret"
    Set-Content -LiteralPath $rcloneConfig -Value "[s3]`ntype=s3"

    function ConvertTo-Psd1String([string] $Value) {
        return "'$($Value.Replace("'", "''"))'"
    }

    $script:ConfigPath = Join-Path $script:TestRoot 'config.psd1'
    $configText = @"
@{
    InstanceName = 'TEST-SERVER'
    Tools = @{
        MySqlDump = $(ConvertTo-Psd1String $script:MySqlDump)
        MySql = $(ConvertTo-Psd1String $script:MySql)
        SevenZip = $(ConvertTo-Psd1String $script:SevenZip)
        Rclone = $(ConvertTo-Psd1String $script:Rclone)
    }
    Database = @{
        Name = 'seven'
        DefaultsExtraFile = $(ConvertTo-Psd1String $script:DefaultsFile)
        ExtraArguments = @()
    }
    Fiscal = @{ SourcePath = $(ConvertTo-Psd1String $fiscal) }
    Storage = @{
        ConfigPath = $(ConvertTo-Psd1String $rcloneConfig)
        RemoteRoot = 's3:bucket/backups'
    }
    Archive = @{ CompressionLevel = 5; CpuLimitPercent = 50 }
    Paths = @{
        RuntimeRoot = $(ConvertTo-Psd1String $script:Runtime)
        CompletedRoot = $(ConvertTo-Psd1String $script:Completed)
        LogRoot = $(ConvertTo-Psd1String $script:Logs)
    }
    Retention = @{ CompletedDays = 7; LogDays = 30 }
}
"@
    Set-Content -LiteralPath $script:ConfigPath -Value $configText
}

AfterEach {
    foreach ($name in @(
        'BACKUPSEVEN_FAKE_7ZIP_CREATE_EXIT',
        'BACKUPSEVEN_FAKE_7ZIP_TEST_EXIT',
        'BACKUPSEVEN_FAKE_RCLONE_LIST_EXIT',
        'BACKUPSEVEN_FAKE_RCLONE_COPY_EXIT',
        'BACKUPSEVEN_FAKE_RCLONE_CHECK_EXIT',
        'BACKUPSEVEN_FAKE_RCLONE_LOG_COPY_EXIT',
        'BACKUPSEVEN_FAKE_RCLONE_LOG_CHECK_EXIT',
        'BACKUPSEVEN_FAKE_RCLONE_FAIL_MATCH',
        'BACKUPSEVEN_FAKE_MYSQLDUMP_EXIT',
        'BACKUPSEVEN_FAKE_MYSQLDUMP_NORMAL_EXIT',
        'BACKUPSEVEN_FAKE_MYSQLDUMP_FORCE_EXIT',
        'BACKUPSEVEN_FAKE_MYSQLDUMP_FAILED_OBJECT',
        'BACKUPSEVEN_FAKE_MYSQL_EXIT',
        'BACKUPSEVEN_FAKE_MYSQL_OBJECTS',
        'BACKUPSEVEN_FAKE_INVOCATION_LOG'
    )) {
        [Environment]::SetEnvironmentVariable($name, $null)
    }

    if (Test-Path -LiteralPath $script:TestRoot) {
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force
    }
}

Context 'End-to-end orchestration' {
    It 'completes a Database backup and leaves no work files' {
        $exitCode = Invoke-TestBackup -Mode Database
        if ($exitCode -ne 0) {
            throw "Database backup exited with $exitCode. $($script:LastBackupOutput -join [Environment]::NewLine)"
        }
        $exitCode | Should -Be 0

        @(Get-ChildItem (Join-Path $script:Completed 'Database') -Filter '*.7z' -File).Count |
            Should -Be 1
        @(Get-ChildItem (Join-Path $script:Runtime 'Pending/Database') -Filter '*.7z' -File -Recurse).Count |
            Should -Be 0
        @(Get-ChildItem (Join-Path $script:Runtime 'Work') -Force).Count | Should -Be 0
        $archive = Get-ChildItem (Join-Path $script:Completed 'Database') -Filter '*.7z' -File |
            Select-Object -First 1
        $archive.Name | Should -Match '^BackupSeven_\d{4}-\d{2}-\d{2}_\d{6}Z_TEST-SERVER_Database_[a-f0-9]{8}\.7z$'
        $archiveContent = Get-Content -LiteralPath $archive.FullName -Raw
        $archiveContent | Should -Match 'ENTRY:manifest\.json'
        $archiveContent | Should -Match '"status":\s*"SUCCESS"'

        $logFiles = @(Get-ChildItem $script:Logs -Filter '*.log' -File)
        $logFiles.Count | Should -Be 1
        $logFiles[0].Name | Should -Match '^BackupSevenLog_\d{4}-\d{2}-\d{2}_\d{6}Z_TEST-SERVER_Database_[a-f0-9]{8}\.log$'
        @(Get-ChildItem $script:Logs -Directory).Count | Should -Be 0

        $logContent = $logFiles |
            ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }
        $logContent -join [Environment]::NewLine | Should -Not -Match 'super-secret'
        $logContent -join [Environment]::NewLine |
            Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \[INFO\] \[[a-f0-9]{32}\] \[Database/Startup\]'
        $logContent -join [Environment]::NewLine | Should -Not -Match '\[Database/Database/'

        $invocations = Get-Content -LiteralPath $script:InvocationLog
        $invocations -join [Environment]::NewLine |
            Should -Match 'copyto\|.*\.7z\|s3:bucket/backups/TEST-SERVER/Database/\d{4}/\d{2}/\d{2}/BackupSeven_'
        $invocations -join [Environment]::NewLine |
            Should -Match 'copyto\|.*\.log\|s3:bucket/backups/TEST-SERVER/Logs/\d{4}/\d{2}/\d{2}/BackupSevenLog_'
    }

    It 'keeps an unconfirmed Fiscal archive pending and retries it next time' {
        $env:BACKUPSEVEN_FAKE_RCLONE_CHECK_EXIT = '1'
        Invoke-TestBackup -Mode Fiscal | Should -Be 1
        @(Get-ChildItem (Join-Path $script:Runtime 'Pending/Fiscal') -Filter '*.7z' -File -Recurse).Count |
            Should -Be 1

        $env:BACKUPSEVEN_FAKE_RCLONE_CHECK_EXIT = $null
        Invoke-TestBackup -Mode Fiscal | Should -Be 0
        @(Get-ChildItem (Join-Path $script:Runtime 'Pending/Fiscal') -Filter '*.7z' -File -Recurse).Count |
            Should -Be 0
        @(Get-ChildItem (Join-Path $script:Completed 'Fiscal') -Filter '*.7z' -File).Count |
            Should -Be 2
    }

    It 'returns failure and preserves the local log when remote log validation fails' {
        $env:BACKUPSEVEN_FAKE_RCLONE_LOG_CHECK_EXIT = '1'

        Invoke-TestBackup -Mode Database | Should -Be 1

        @(Get-ChildItem (Join-Path $script:Completed 'Database') -Filter '*.7z' -File).Count |
            Should -Be 1
        $logFiles = @(Get-ChildItem $script:Logs -Filter '*.log' -File)
        $logFiles.Count | Should -Be 1
        Get-Content -LiteralPath $logFiles[0].FullName -Raw | Should -Match 'rclone check failed'
    }

    It 'publishes both degraded archives and returns exit code 5' {
        $env:BACKUPSEVEN_FAKE_MYSQLDUMP_NORMAL_EXIT = '2'
        $env:BACKUPSEVEN_FAKE_MYSQLDUMP_FORCE_EXIT = '2'
        $env:BACKUPSEVEN_FAKE_MYSQLDUMP_FAILED_OBJECT = 'produtos'

        $exitCode = Invoke-TestBackup -Mode Database
        if ($exitCode -ne 5) {
            throw "Degraded Database backup exited with $exitCode. $($script:LastBackupOutput -join [Environment]::NewLine)"
        }
        $exitCode | Should -Be 5

        $archives = @(Get-ChildItem (Join-Path $script:Completed 'Database') -Filter '*.7z' -File)
        $archives.Count | Should -Be 2
        @($archives.Name | Where-Object { $_ -match '_DEGRADED\.7z$' }).Count | Should -Be 2
        @($archives.Name | Where-Object { $_ -match '_GRANULAR_DEGRADED\.7z$' }).Count | Should -Be 1

        $granularArchive = $archives | Where-Object Name -Match '_GRANULAR_DEGRADED\.7z$'
        $granularContent = Get-Content -LiteralPath $granularArchive.FullName -Raw
        $granularContent | Should -Match 'ENTRY:manifest\.json'
        $granularContent | Should -Match 'Granular/seven/produtos_FAILED\.txt'
        $granularContent | Should -Match 'marked as crashed and should be repaired \(145\)'
        $granularContent | Should -Match '"objectType":\s*"VIEW"'

        $logContent = Get-ChildItem $script:Logs -Filter '*.log' -File |
            ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }
        $logContent -join [Environment]::NewLine | Should -Match '\[WARN\].*\[Database/Degraded\]'
        $logContent -join [Environment]::NewLine | Should -Not -Match 'Execution completed successfully'
    }

    It 'preserves the general degraded archive and returns failure when enumeration fails' {
        $env:BACKUPSEVEN_FAKE_MYSQLDUMP_NORMAL_EXIT = '2'
        $env:BACKUPSEVEN_FAKE_MYSQL_EXIT = '1'

        $exitCode = Invoke-TestBackup -Mode Database
        if ($exitCode -ne 1) {
            throw "Partial degraded Database backup exited with $exitCode. $($script:LastBackupOutput -join [Environment]::NewLine)"
        }
        $exitCode | Should -Be 1

        $archives = @(Get-ChildItem (Join-Path $script:Completed 'Database') -Filter '*.7z' -File)
        $archives.Count | Should -Be 1
        $archives[0].Name | Should -Match '_DEGRADED\.7z$'
        $archives[0].Name | Should -Not -Match '_GRANULAR_DEGRADED\.7z$'
    }

    It 'keeps a failed degraded upload pending and retries it on the next run' {
        $env:BACKUPSEVEN_FAKE_MYSQLDUMP_NORMAL_EXIT = '2'
        $env:BACKUPSEVEN_FAKE_MYSQLDUMP_FORCE_EXIT = '2'
        $env:BACKUPSEVEN_FAKE_RCLONE_FAIL_MATCH = 'GRANULAR_DEGRADED'

        Invoke-TestBackup -Mode Database | Should -Be 1
        @(Get-ChildItem (Join-Path $script:Completed 'Database') -Filter '*_DEGRADED.7z' -File).Count | Should -Be 1
        @(Get-ChildItem (Join-Path $script:Runtime 'Pending/Database') -Filter '*_GRANULAR_DEGRADED.7z' -File -Recurse).Count | Should -Be 1

        $env:BACKUPSEVEN_FAKE_MYSQLDUMP_NORMAL_EXIT = $null
        $env:BACKUPSEVEN_FAKE_MYSQLDUMP_FORCE_EXIT = $null
        $env:BACKUPSEVEN_FAKE_RCLONE_FAIL_MATCH = $null
        Invoke-TestBackup -Mode Database | Should -Be 0

        @(Get-ChildItem (Join-Path $script:Runtime 'Pending/Database') -Filter '*.7z' -File -Recurse).Count | Should -Be 0
        @(Get-ChildItem (Join-Path $script:Completed 'Database') -Filter '*.7z' -File).Count | Should -Be 3
    }

    It 'continues Fiscal when the Database fallback is incomplete in Full mode' {
        $env:BACKUPSEVEN_FAKE_MYSQLDUMP_NORMAL_EXIT = '2'
        $env:BACKUPSEVEN_FAKE_MYSQL_EXIT = '1'

        $exitCode = Invoke-TestBackup -Mode Full
        if ($exitCode -ne 1) {
            throw "Full backup with incomplete Database fallback exited with $exitCode. $($script:LastBackupOutput -join [Environment]::NewLine)"
        }
        $exitCode | Should -Be 1

        @(Get-ChildItem (Join-Path $script:Completed 'Database') -Filter '*.7z' -File).Count |
            Should -Be 1
        @(Get-ChildItem (Join-Path $script:Completed 'Fiscal') -Filter '*.7z' -File).Count |
            Should -Be 1
    }

    It 'returns exit code 3 when the run lock is held' {
        $null = New-Item -ItemType Directory -Path $script:Runtime -Force
        $lockPath = Join-Path $script:Runtime 'BackupSeven.lock'
        $lock = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
        try {
            Invoke-TestBackup -Mode Database | Should -Be 3
            @(Get-ChildItem (Join-Path $script:Runtime 'Work') -Force).Count | Should -Be 0
        }
        finally {
            $lock.Dispose()
        }
    }

    It 'removes only expired completed archives' {
        $completedDirectory = Join-Path $script:Completed 'Database'
        $pendingDirectory = Join-Path $script:Runtime 'Pending/Fiscal/2020/01'
        $null = New-Item -ItemType Directory -Path $completedDirectory, $pendingDirectory -Force
        $completedArchive = Join-Path $completedDirectory 'BackupSeven_2020-01-01_000000Z_TEST-SERVER_Database_deadbeef.7z'
        $pendingArchive = Join-Path $pendingDirectory 'BackupSeven_2020-01-01_000000Z_TEST-SERVER_Fiscal_deadbeef.7z'
        Set-Content -LiteralPath $completedArchive, $pendingArchive -Value 'archive'

        $null = New-Item -ItemType Directory -Path $script:Logs -Force
        $expiredLog = Join-Path $script:Logs 'BackupSevenLog_2020-01-01_000000Z_TEST-SERVER_Database_deadbeef.log'
        Set-Content -LiteralPath $expiredLog -Value 'old log'

        Invoke-TestBackup -Mode Database | Should -Be 0

        Test-Path -LiteralPath $completedArchive | Should -BeFalse
        Test-Path -LiteralPath $pendingArchive | Should -BeTrue
        Test-Path -LiteralPath $expiredLog | Should -BeFalse
    }

    It 'returns exit code 2 for an invalid configuration' {
        Set-Content -LiteralPath $script:ConfigPath -Value '@{}'

        Invoke-TestBackup -Mode Database | Should -Be 2
    }
}
}
