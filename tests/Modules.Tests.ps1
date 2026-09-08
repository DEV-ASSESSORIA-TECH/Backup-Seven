Describe 'BackupSeven module contracts' {
BeforeAll {
    $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("BackupSeven-modules-$([guid]::NewGuid().ToString('N'))")
    $null = New-Item -ItemType Directory -Path $script:TestRoot
    $fakeTool = Join-Path $script:TestRoot 'fake-tool.exe'
    $compiler = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $compiler '/nologo' '/target:exe' "/out:$fakeTool" (Join-Path $PSScriptRoot 'fixtures/FakeExternalTool.cs')
    if ($LASTEXITCODE -ne 0) {
        throw "Fake tool compilation failed with exit code $LASTEXITCODE."
    }

    $script:SevenZip = Join-Path $script:TestRoot '7z.exe'
    $script:MySqlDump = Join-Path $script:TestRoot 'mysqldump.exe'
    $script:Rclone = Join-Path $script:TestRoot 'rclone.exe'
    $script:InvocationLog = Join-Path $script:TestRoot 'tool-invocations.log'
    $env:BACKUPSEVEN_FAKE_INVOCATION_LOG = $script:InvocationLog
    Copy-Item $fakeTool $script:SevenZip
    Copy-Item $fakeTool $script:MySqlDump
    Copy-Item $fakeTool $script:Rclone

    $script:DefaultsFile = Join-Path $script:TestRoot 'mysql.cnf'
    $script:RcloneConfig = Join-Path $script:TestRoot 'rclone.conf'
    Set-Content -LiteralPath $script:DefaultsFile -Value "[client]`nuser=test"
    Set-Content -LiteralPath $script:RcloneConfig -Value "[s3]`ntype=s3"

    Import-Module (Join-Path $PSScriptRoot '../src/Modules/Archive.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../src/Modules/Database.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../src/Modules/Storage.psm1') -Force
}

AfterAll {
    foreach ($name in @(
        'BACKUPSEVEN_FAKE_7ZIP_CREATE_EXIT',
        'BACKUPSEVEN_FAKE_7ZIP_TEST_EXIT',
        'BACKUPSEVEN_FAKE_RCLONE_LIST_EXIT',
        'BACKUPSEVEN_FAKE_RCLONE_COPY_EXIT',
        'BACKUPSEVEN_FAKE_RCLONE_CHECK_EXIT',
        'BACKUPSEVEN_FAKE_MYSQLDUMP_EXIT',
        'BACKUPSEVEN_FAKE_INVOCATION_LOG'
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

        $result = New-SevenArchive -SevenZipPath $script:SevenZip -SourcePath $source -ArchivePath $archive

        $result.Length | Should -BeGreaterThan 0
        Test-Path -LiteralPath $archive | Should -BeTrue
    }

    It 'limits 7-Zip threads from the configured CPU percentage' {
        $source = Join-Path $script:TestRoot 'cpu-source.txt'
        $archive = Join-Path $script:TestRoot 'cpu-limited.7z'
        Set-Content -LiteralPath $source -Value 'content'
        $expectedThreads = [Math]::Max(1, [Math]::Floor([Environment]::ProcessorCount * 0.5))

        $null = New-SevenArchive `
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
        $env:BACKUPSEVEN_FAKE_7ZIP_CREATE_EXIT = '1'

        { New-SevenArchive -SevenZipPath $script:SevenZip -SourcePath $source -ArchivePath $archive } |
            Should -Throw '*exit code 1*'
        Test-Path -LiteralPath $archive | Should -BeFalse

        $env:BACKUPSEVEN_FAKE_7ZIP_CREATE_EXIT = $null
    }

    It 'removes an archive that fails the integrity test' {
        $source = Join-Path $script:TestRoot 'invalid-source.txt'
        $archive = Join-Path $script:TestRoot 'invalid.7z'
        Set-Content -LiteralPath $source -Value 'content'
        $env:BACKUPSEVEN_FAKE_7ZIP_TEST_EXIT = '2'

        { New-SevenArchive -SevenZipPath $script:SevenZip -SourcePath $source -ArchivePath $archive } |
            Should -Throw '*validation failed*'
        Test-Path -LiteralPath $archive | Should -BeFalse

        $env:BACKUPSEVEN_FAKE_7ZIP_TEST_EXIT = $null
    }
}

Context 'Database module' {
    It 'streams a non-empty database dump to disk' {
        $dump = Join-Path $script:TestRoot 'database.sql'

        $result = New-SevenDatabaseDump `
            -MySqlDumpPath $script:MySqlDump `
            -DefaultsExtraFile $script:DefaultsFile `
            -DatabaseName seven `
            -OutputPath $dump

        $result.Length | Should -BeGreaterThan 0
        Get-Content -LiteralPath $dump -Raw | Should -Match 'CREATE DATABASE'
    }

    It 'rejects passwords in extra arguments' {
        $dump = Join-Path $script:TestRoot 'password.sql'

        { New-SevenDatabaseDump `
                -MySqlDumpPath $script:MySqlDump `
                -DefaultsExtraFile $script:DefaultsFile `
                -DatabaseName seven `
                -OutputPath $dump `
                -ExtraArguments '--password=secret' } | Should -Throw '*must not contain a password*'
    }
}

Context 'Storage module' {
    It 'finds the configured remote and validates an uploaded file' {
        $archive = Join-Path $script:TestRoot 'upload.7z'
        Set-Content -LiteralPath $archive -Value 'archive'

        Test-SevenStorageConfiguration `
            -RclonePath $script:Rclone `
            -ConfigPath $script:RcloneConfig `
            -RemoteRoot 's3:bucket/backups' | Should -BeTrue

        Send-SevenBackupFile `
            -RclonePath $script:Rclone `
            -ConfigPath $script:RcloneConfig `
            -LocalPath $archive `
            -RemotePath 's3:bucket/backups/upload.7z' | Should -Be 's3:bucket/backups/upload.7z'
    }

    It 'fails when remote validation fails' {
        $archive = Join-Path $script:TestRoot 'failed-check.7z'
        Set-Content -LiteralPath $archive -Value 'archive'
        $env:BACKUPSEVEN_FAKE_RCLONE_CHECK_EXIT = '1'

        { Send-SevenBackupFile `
                -RclonePath $script:Rclone `
                -ConfigPath $script:RcloneConfig `
                -LocalPath $archive `
                -RemotePath 's3:bucket/backups/failed-check.7z' } | Should -Throw '*rclone check failed*'

        $env:BACKUPSEVEN_FAKE_RCLONE_CHECK_EXIT = $null
    }
}
}
