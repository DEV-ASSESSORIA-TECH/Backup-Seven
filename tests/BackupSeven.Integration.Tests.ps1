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
        if ($exitCode -ne 0 -and (Test-Path -LiteralPath $script:Runtime)) {
            $logLines = @(Get-ChildItem -LiteralPath $script:Runtime -Filter '*.log' -File -Recurse |
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
    $script:Rclone = Join-Path $tools 'rclone.exe'
    Copy-Item $fakeTool $script:SevenZip
    Copy-Item $fakeTool $script:MySqlDump
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
    Archive = @{ CompressionLevel = 5 }
    Paths = @{ RuntimeRoot = $(ConvertTo-Psd1String $script:Runtime) }
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
        'BACKUPSEVEN_FAKE_MYSQLDUMP_EXIT'
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

        @(Get-ChildItem (Join-Path $script:Runtime 'Completed/Database') -Filter '*.7z' -File -Recurse).Count |
            Should -Be 1
        @(Get-ChildItem (Join-Path $script:Runtime 'Pending/Database') -Filter '*.7z' -File -Recurse).Count |
            Should -Be 0
        @(Get-ChildItem (Join-Path $script:Runtime 'Work') -Force).Count | Should -Be 0
        $logContent = Get-ChildItem (Join-Path $script:Runtime 'Logs') -Filter '*.log' -File -Recurse |
            ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }
        $logContent -join [Environment]::NewLine | Should -Not -Match 'super-secret'
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
        @(Get-ChildItem (Join-Path $script:Runtime 'Completed/Fiscal') -Filter '*.7z' -File -Recurse).Count |
            Should -Be 2
    }

    It 'continues Fiscal when Database fails in Full mode' {
        $env:BACKUPSEVEN_FAKE_MYSQLDUMP_EXIT = '2'

        Invoke-TestBackup -Mode Full | Should -Be 1

        @(Get-ChildItem (Join-Path $script:Runtime 'Completed/Database') -Filter '*.7z' -File -Recurse).Count |
            Should -Be 0
        @(Get-ChildItem (Join-Path $script:Runtime 'Completed/Fiscal') -Filter '*.7z' -File -Recurse).Count |
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
        $completedDirectory = Join-Path $script:Runtime 'Completed/Database/2020/01'
        $pendingDirectory = Join-Path $script:Runtime 'Pending/Fiscal/2020/01'
        $null = New-Item -ItemType Directory -Path $completedDirectory, $pendingDirectory -Force
        $completedArchive = Join-Path $completedDirectory 'BackupSeven_TEST-SERVER_Database_20200101T000000Z_deadbeef.7z'
        $pendingArchive = Join-Path $pendingDirectory 'BackupSeven_TEST-SERVER_Fiscal_20200101T000000Z_deadbeef.7z'
        Set-Content -LiteralPath $completedArchive, $pendingArchive -Value 'archive'

        Invoke-TestBackup -Mode Database | Should -Be 0

        Test-Path -LiteralPath $completedArchive | Should -BeFalse
        Test-Path -LiteralPath $pendingArchive | Should -BeTrue
    }

    It 'returns exit code 2 for an invalid configuration' {
        Set-Content -LiteralPath $script:ConfigPath -Value '@{}'

        Invoke-TestBackup -Mode Database | Should -Be 2
    }
}
}
