BeforeAll {
    $ErrorActionPreference = 'Stop'
    $script:Repo = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'V1.TestSupport.ps1')
    Import-Module "$script:Repo/src/Modules/Core/Configuration.psm1" -Force
    Import-Module "$script:Repo/src/Modules/Core/Runtime.psm1" -Force
    Import-Module "$script:Repo/src/Modules/Core/Encryption.psm1"
    Import-Module "$script:Repo/src/Modules/Core/Artifacts.psm1"
    Import-Module "$script:Repo/src/Modules/Core/Runner.psm1"
}
Describe 'Encrypted pipeline with simulated external tools' {
    BeforeAll {
        $script:FixtureConfig = New-DBTestFixture (Join-Path $TestDrive 'fixture') $script:Repo
    }
    BeforeEach {
        Clear-DBTestEnvironment
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory $script:Root
        Copy-Item (Split-Path $script:FixtureConfig) (Join-Path $script:Root 'instance') -Recurse
        $script:Config = Join-Path $script:Root 'instance/config.psd1'
        Mock Set-Acl {} -ModuleName Runtime
        $env:DBBACKUP_FAKE_INVOCATION_LOG = Join-Path $script:Root 'calls.txt'
    }
    AfterEach { Clear-DBTestEnvironment }
    It 'publishes a bundle with manifest and encrypted payload metadata' {
        $code = Invoke-DBBackup -ConfigPath $script:Config -All
        if ($code -ne 0) { Get-ChildItem "$script:Root/instance/Logs" -File | ForEach-Object { Get-Content $_.FullName | Write-Host } }
        $code | Should -Be 0
        $bundle = Get-ChildItem "$script:Root/instance/Completed/database" -Directory
        $c = Read-DBConfiguration $script:Config
        $s = Read-DBArtifact $bundle.FullName $c
        $s.Transport | Should -Be CONFIRMED
        $s.LocalStatus | Should -Be SUCCESS
        $s.FileName | Should -BeLike '*.7z.age'
        # Fixture copies bytes instead of encrypting: inspect orchestration only.
        Get-Content (Join-Path $bundle.FullName $s.FileName) -Raw | Should -Match 'manifest.json'
        Get-Content $env:DBBACKUP_FAKE_INVOCATION_LOG -Raw | Should -Not -Match 'fake-secret'
        @(Get-ChildItem "$script:Root/instance/Runtime/Work").Count | Should -Be 0
    }
    It 'never queues an incomplete encryption result' {
        $env:DBBACKUP_FAKE_AGE_EXIT='1'
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 1
        @(Get-ChildItem "$script:Root/instance/Runtime/Pending" -Recurse -File).Count | Should -Be 0
        @(Get-ChildItem "$script:Root/instance/Runtime/Staging").Count | Should -Be 0
    }
    It 'never queues an archive that fails its integrity test' {
        $env:DBBACKUP_FAKE_7ZIP_TEST_EXIT='2'
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 1
        @(Get-ChildItem "$script:Root/instance/Runtime/Pending" -Recurse -File).Count | Should -Be 0
    }
    It 'retries the same bytes at the recorded destination after configuration changes' {
        $env:DBBACKUP_FAKE_RCLONE_CHECK_EXIT='1'
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 1
        $pending = Get-ChildItem "$script:Root/instance/Runtime/Pending/database" -Directory
        $s = Read-DBArtifact $pending.FullName (Read-DBConfiguration $script:Config)
        Set-Content $script:Config ((Get-Content $script:Config -Raw).Replace('s3:test-bucket', 's3:new-bucket'))
        $env:DBBACKUP_FAKE_RCLONE_CHECK_EXIT='0'
        $code = Invoke-DBBackup -ConfigPath $script:Config -All
        if ($code -ne 0) { Get-ChildItem "$script:Root/instance/Logs" -File | ForEach-Object { Get-Content $_.FullName | Write-Host } }
        $code | Should -Be 0
        $state = Get-Content (Join-Path "$script:Root/instance/Completed/database/$($pending.Name)" 'state.json') -Raw | ConvertFrom-Json
        $state.Sha256 | Should -Be $s.Sha256
        $state.RemotePath | Should -Be $s.RemotePath
        Get-Content $env:DBBACKUP_FAKE_INVOCATION_LOG -Raw | Should -Match ([regex]::Escape($s.RemotePath))
    }
    It 'fails closed on an altered pending payload and still produces a new backup' {
        $env:DBBACKUP_FAKE_RCLONE_COPY_EXIT='1'
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 1
        $payload = Get-ChildItem "$script:Root/instance/Runtime/Pending" -Recurse -Filter '*.age'
        Add-Content $payload.FullName 'tampered'
        $env:DBBACKUP_FAKE_RCLONE_COPY_EXIT='0'
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 1
        Test-Path $payload.FullName | Should -BeTrue
        @(Get-ChildItem "$script:Root/instance/Completed/database" -Directory).Count | Should -Be 1
    }
    It 'publishes both degraded artifacts with exit code five' {
        $env:DBBACKUP_FAKE_MYSQLDUMP_NORMAL_EXIT='2'
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 5
        $states = @(Get-ChildItem "$script:Root/instance/Completed" -Recurse -Filter state.json | ForEach-Object {Get-Content $_.FullName -Raw | ConvertFrom-Json})
        $states.Count | Should -Be 2
        $states.LocalStatus | Should -Be @('DEGRADED','DEGRADED')
    }
    It 'rejects a private key or an empty recipients file' {
        $path=Join-Path $script:Root 'recipients.txt'
        Set-Content $path 'AGE-SECRET-KEY-1PRIVATE'
        { Read-DBRecipients $path } | Should -Throw '*public*'
        Set-Content $path '# no recipients'
        { Read-DBRecipients $path } | Should -Throw '*At least*'
    }
}
