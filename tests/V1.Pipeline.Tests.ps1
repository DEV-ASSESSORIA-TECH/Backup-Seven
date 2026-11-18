BeforeAll {
    $ErrorActionPreference = 'Stop'
    $script:Repo = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'V1.TestSupport.ps1')
    Import-Module "$script:Repo/src/App/Modules/Core/Configuration.psm1"
    Import-Module "$script:Repo/src/App/Modules/Core/Runtime.psm1"
    Import-Module "$script:Repo/src/App/Modules/Core/Encryption.psm1"
    Import-Module "$script:Repo/src/App/Modules/Core/Artifacts.psm1"
    Import-Module "$script:Repo/src/App/Modules/Core/Runner.psm1"
}
Describe 'Encrypted pipeline with simulated external tools' {
    BeforeAll {
        $script:FixtureConfig = New-DBTestFixture (Join-Path $TestDrive 'fixture') $script:Repo
    }
    BeforeEach {
        Clear-DBTestEnvironment
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory $script:Root
        Copy-Item (Split-Path $script:FixtureConfig) (Join-Path $script:Root 'instance') -Recurse
        $script:Config = Join-Path $script:Root 'instance/config.psd1'
        Mock Set-Acl {} -ModuleName Runtime
        $env:DBBACKUP_FAKE_INVOCATION_LOG = Join-Path $script:Root 'calls.txt'
    }
    AfterEach { Clear-DBTestEnvironment }
    It 'publishes a bundle with manifest and encrypted payload metadata' {
        $code = Invoke-DBBackup -ConfigPath $script:Config -All
        if ($code -ne 0) { Get-ChildItem "$script:Root/instance/Logs" -File | ForEach-Object { Get-Content $_.FullName | Write-Information -InformationAction Continue } }
        $code | Should -Be 0
        $bundle = Get-ChildItem "$script:Root/instance/Completed/database" -Directory
        $c = Read-DBConfiguration $script:Config
        $s = Read-DBArtifact $bundle.FullName $c
        $s.Transport | Should -Be CONFIRMED
        $s.LocalStatus | Should -Be SUCCESS
        $s.FileName | Should -BeLike '*.7z.age'
        # RemoteRoot is the full destination: no instance name is inserted.
        $s.RemotePath | Should -BeExactly ('s3:test-bucket/database/{0}/{1}' -f ([datetime]$s.RecoveryPointUtc).ToLocalTime().ToString('yyyy/MM/dd'), $s.FileName)
        # Readable name: local timestamp first, then instance and job; no run ID.
        $s.FileName | Should -Match '^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_MySQL_database\.7z\.age$'
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
        if ($code -ne 0) { Get-ChildItem "$script:Root/instance/Logs" -File | ForEach-Object { Get-Content $_.FullName | Write-Information -InformationAction Continue } }
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
        @($states.FileName | Sort-Object) | Should -Match '_MySQL_database_(GERAL|GRANULAR)\.7z\.age$'
    }
    It 'rejects a private key or an empty recipients file' {
        $path=Join-Path $script:Root 'recipients.txt'
        Set-Content $path 'AGE-SECRET-KEY-1PRIVATE'
        { Read-DBRecipient $path } | Should -Throw '*public*'
        Set-Content $path '# no recipients'
        { Read-DBRecipient $path } | Should -Throw '*At least*'
    }
    It 'runs a directory-only job without requiring unused database executables' {
        $source=Join-Path $script:Root 'documents'
        $null=New-Item -ItemType Directory $source
        Set-Content (Join-Path $source 'file.txt') 'document'
        Add-DBTestJob $script:Config "@{Id='documents';Provider='Directory';SourcePath='$($source.Replace("'","''"))';RemoteRoot='s3:test-bucket'}"
        Set-Content $script:Config ((Get-Content $script:Config -Raw).Replace('mysql.exe','absent-mysql.exe').Replace('mysqldump.exe','absent-mysqldump.exe'))
        Invoke-DBBackup -ConfigPath $script:Config -Job documents | Should -Be 0
        @(Get-ChildItem "$script:Root/instance/Completed/documents" -Directory).Count | Should -Be 1
    }
    It 'continues directory jobs after an incomplete MySQL fallback' {
        $source=Join-Path $script:Root 'documents'
        $null=New-Item -ItemType Directory $source
        Set-Content (Join-Path $source 'file.txt') 'document'
        Add-DBTestJob $script:Config "@{Id='documents';Provider='Directory';SourcePath='$($source.Replace("'","''"))';RemoteRoot='s3:test-bucket'}"
        $env:DBBACKUP_FAKE_MYSQLDUMP_NORMAL_EXIT='2'
        $env:DBBACKUP_FAKE_MYSQL_EXIT='1'
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 1
        @(Get-ChildItem "$script:Root/instance/Completed/documents" -Directory).Count | Should -Be 1
        @(Get-ChildItem "$script:Root/instance/Completed/database" -Directory).Count | Should -Be 1
    }
    It 'removes plaintext left by an interrupted run but never Pending or unknown items' {
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 0
        $runtime = "$script:Root/instance/Runtime"
        $staleWork = Join-Path $runtime "Work/$('a' * 32)/_secrets"
        $null = New-Item -ItemType Directory $staleWork -Force
        Set-Content (Join-Path $staleWork 'backup.options') '-c "PWD=left-behind"'
        $staleBundle = Join-Path $runtime 'Staging/2026-01-01_00-00-00_MySQL_database'
        $null = New-Item -ItemType Directory $staleBundle -Force
        Set-Content (Join-Path $staleBundle 'payload.tmp') 'partial'
        $unknown = Join-Path $runtime 'Work/operator-notes'
        $null = New-Item -ItemType Directory $unknown
        $pendingMarker = Join-Path $runtime 'Pending/keep-me'
        $null = New-Item -ItemType Directory $pendingMarker -Force
        Invoke-DBBackup -ConfigPath $script:Config -Job database | Should -Be 4
        Test-Path (Join-Path $runtime "Work/$('a' * 32)") | Should -BeFalse
        Test-Path $staleBundle | Should -BeFalse
        Test-Path $unknown | Should -BeTrue
        Test-Path $pendingMarker | Should -BeTrue
        $log = Get-ChildItem "$script:Root/instance/Logs" -File | Sort-Object LastWriteTimeUtc | Select-Object -Last 1
        Get-Content $log.FullName -Raw | Should -Match 'interrupted run'
        Get-Content $log.FullName -Raw | Should -Not -Match 'left-behind'
    }
    It 'reports an auxiliary failure with exit four when only cleanup finds unknown items' {
        $null = New-Item -ItemType Directory "$script:Root/instance/Runtime/Work/operator-notes" -Force
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 4
        @(Get-ChildItem "$script:Root/instance/Completed/database" -Directory).Count | Should -Be 1
    }
    It 'fails jobs that would start after the run deadline and still cleans Work' {
        Mock Assert-DBToolDeadline { throw [TimeoutException]::new('Run deadline exceeded (test).') } -ModuleName Runner
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 1
        @(Get-ChildItem "$script:Root/instance/Runtime/Work").Count | Should -Be 0
        Test-Path "$script:Root/instance/Completed/database" | Should -BeFalse
    }
    It 'continues retention past an unreadable bundle and reports exit four' {
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 0
        $completed = "$script:Root/instance/Completed/database"
        $bundle = Get-ChildItem $completed -Directory | Select-Object -First 1
        $expired = Join-Path $completed 'DBBackup_expired_copy'
        Copy-Item $bundle.FullName $expired -Recurse
        $state = Get-Content (Join-Path $expired 'state.json') -Raw | ConvertFrom-Json
        $state.RecoveryPointUtc = '2000-01-01T00:00:00.0000000Z'
        $state | ConvertTo-Json | Set-Content (Join-Path $expired 'state.json')
        $corrupt = Join-Path $completed 'DBBackup_corrupt'
        $null = New-Item -ItemType Directory $corrupt
        Set-Content (Join-Path $corrupt 'state.json') 'not json'
        $oldLog = Join-Path "$script:Root/instance/Logs" "2000-01-01_00-00-00.log"
        Set-Content $oldLog 'old'
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 4
        Test-Path $expired | Should -BeFalse
        Test-Path $oldLog | Should -BeFalse
        Test-Path $corrupt | Should -BeTrue
    }
    It 'treats a failed log upload as an auxiliary failure, not a failed backup' {
        $env:DBBACKUP_FAKE_RCLONE_LOG_COPY_EXIT='1'
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 4
        @(Get-ChildItem "$script:Root/instance/Completed/database" -Directory).Count | Should -Be 1
    }
    It 'keeps degraded precedence over auxiliary failures' {
        $env:DBBACKUP_FAKE_MYSQLDUMP_NORMAL_EXIT='2'
        $env:DBBACKUP_FAKE_RCLONE_LOG_COPY_EXIT='1'
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 5
    }
    It 'drops the local encrypted copy after confirmed upload when configured' {
        Set-Content $script:Config ((Get-Content $script:Config -Raw).Replace('KeepLocalPayload = $true', 'KeepLocalPayload = $false'))
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 0
        $bundle = Get-ChildItem "$script:Root/instance/Completed/database" -Directory
        @(Get-ChildItem $bundle.FullName -Filter '*.age').Count | Should -Be 0
        $s = Read-DBArtifact $bundle.FullName (Read-DBConfiguration $script:Config)
        $s.LocalPayload | Should -Be 'REMOVED'
        $s.Sha256 | Should -Not -BeNullOrEmpty
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 0
    }
    It 'estimates database space from a probe first and from the last payload afterwards' {
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 0
        Get-Content $env:DBBACKUP_FAKE_INVOCATION_LOG -Raw | Should -Match 'information_schema'
        Test-Path "$script:Root/instance/Runtime/Capacity/database.json" | Should -BeTrue
        Remove-Item $env:DBBACKUP_FAKE_INVOCATION_LOG
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 0
        Get-Content $env:DBBACKUP_FAKE_INVOCATION_LOG -Raw | Should -Not -Match 'information_schema'
        $log = Get-ChildItem "$script:Root/instance/Logs" -File | Sort-Object LastWriteTimeUtc | Select-Object -Last 1
        Get-Content $log.FullName -Raw | Should -Match 'Space estimate: \d+ bytes \(last-payload\+25%\)'
    }
    It 'warns when no database space estimate is available' {
        $env:DBBACKUP_FAKE_MYSQL_SIZE='not-a-number'
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 0
        $log = Get-ChildItem "$script:Root/instance/Logs" -File | Sort-Object LastWriteTimeUtc | Select-Object -Last 1
        Get-Content $log.FullName -Raw | Should -Match 'No space estimate is available'
    }
    It 'archives a directory job in place with the user manifest under content/' {
        $source=Join-Path $script:Root 'documents'
        $null=New-Item -ItemType Directory (Join-Path $source 'sub') -Force
        Set-Content (Join-Path $source 'manifest.json') '{"user":true}'
        Set-Content (Join-Path $source 'sub/file.txt') 'document'
        Add-DBTestJob $script:Config "@{Id='documents';Provider='Directory';SourcePath='$($source.Replace("'","''"))';RemoteRoot='s3:test-bucket'}"
        Invoke-DBBackup -ConfigPath $script:Config -Job documents | Should -Be 0
        $bundle = Get-ChildItem "$script:Root/instance/Completed/documents" -Directory
        $s = Read-DBArtifact $bundle.FullName (Read-DBConfiguration $script:Config)
        $text = Get-Content (Join-Path $bundle.FullName $s.FileName) -Raw
        $text | Should -Match '(?m)^ENTRY:content/manifest\.json\r?$'
        $text | Should -Match '(?m)^ENTRY:content/sub/file\.txt\r?$'
        $text | Should -Match '(?m)^ENTRY:manifest\.json\r?$'
        $text | Should -Match '"Path":\s*"content/sub/file.txt"'
        Get-Content (Join-Path $source 'sub/file.txt') -Raw | Should -Match 'document'
        @(Get-ChildItem "$script:Root/instance/Runtime/Work").Count | Should -Be 0
    }
    It 'removes the plaintext payload before encryption starts' {
        $script:PayloadSeenAtEncryption = $null
        Mock Protect-DBArchive {
            param($InputPath, $OutputPath)
            $work = Split-Path -Parent $InputPath
            $script:PayloadSeenAtEncryption = @(Get-ChildItem -LiteralPath $work -Recurse -File -Filter '*.sql').Count -gt 0
            Copy-Item -LiteralPath $InputPath -Destination $OutputPath
        } -ModuleName Artifacts
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 0
        $script:PayloadSeenAtEncryption | Should -BeFalse
    }
    It 'decides retention from state without re-hashing retained payloads' {
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 0
        $bundle = Get-ChildItem "$script:Root/instance/Completed/database" -Directory
        $payload = Get-ChildItem $bundle.FullName -Filter '*.age'
        $bytes = [IO.File]::ReadAllBytes($payload.FullName)
        $bytes[0] = $bytes[0] -bxor 0xFF
        [IO.File]::WriteAllBytes($payload.FullName, $bytes)
        Mock Get-FileHash { throw 'retention must not hash payloads' } -ModuleName Artifacts -ParameterFilter { $LiteralPath -like '*.age' }
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 0
    }
    It 'verifies uploads from the remote listing and records the MD5 digest' {
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 0
        $calls = Get-Content $env:DBBACKUP_FAKE_INVOCATION_LOG -Raw
        $calls | Should -Match '(?m)^lsjson\|'
        $calls | Should -Not -Match '(?m)^check\|'
        $bundle = Get-ChildItem "$script:Root/instance/Completed/database" -Directory
        $s = Get-Content (Join-Path $bundle.FullName 'state.json') -Raw | ConvertFrom-Json
        # MD5 only mirrors what S3 reports; integrity is the recorded SHA-256.
        $s.Md5 | Should -Be ([Convert]::ToHexString([Security.Cryptography.MD5]::HashData([IO.File]::ReadAllBytes((Join-Path $bundle.FullName $s.FileName)))).ToLowerInvariant())
        $log = Get-ChildItem "$script:Root/instance/Logs" -File | Sort-Object LastWriteTimeUtc | Select-Object -Last 1
        Get-Content $log.FullName -Raw | Should -Match 'remote verification: size\+md5'
    }
    It 'keeps the bundle pending when the remote MD5 differs' {
        $env:DBBACKUP_FAKE_RCLONE_REMOTE_MD5='00000000000000000000000000000000'
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 1
        @(Get-ChildItem "$script:Root/instance/Runtime/Pending/database" -Directory).Count | Should -Be 1
        $env:DBBACKUP_FAKE_RCLONE_REMOTE_MD5=$null
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 0
        @(Get-ChildItem "$script:Root/instance/Completed/database" -Directory).Count | Should -Be 2
    }
    It 'runs a comma-separated job list in order and ends the log with a readable result' {
        $source=Join-Path $script:Root 'documents'
        $null=New-Item -ItemType Directory $source
        Set-Content (Join-Path $source 'file.txt') 'document'
        Add-DBTestJob $script:Config "@{Id='documents';Provider='Directory';SourcePath='$($source.Replace("'","''"))';RemoteRoot='s3:test-bucket'}"
        Invoke-DBBackup -ConfigPath $script:Config -Job 'documents, database' | Should -Be 0
        @(Get-ChildItem "$script:Root/instance/Completed/documents" -Directory).Count | Should -Be 1
        @(Get-ChildItem "$script:Root/instance/Completed/database" -Directory).Count | Should -Be 1
        $log = Get-ChildItem "$script:Root/instance/Logs" -File | Select-Object -First 1
        $log.Name | Should -Match '^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.log$'
        (Get-Content $log.FullName | Select-Object -Last 1) | Should -Match 'RESULTADO: SUCESSO \(exit 0\)$'
        $calls = Get-Content $env:DBBACKUP_FAKE_INVOCATION_LOG -Raw
        $calls | Should -Match ([regex]::Escape("s3:test-bucket/Logs/") + '\d{4}/\d{2}/\d{2}/' + [regex]::Escape("$([IO.Path]::GetFileNameWithoutExtension($log.Name))_MySQL.log"))
        { Invoke-DBBackup -ConfigPath $script:Config -Job 'nope' } | Should -Not -Throw
        Invoke-DBBackup -ConfigPath $script:Config -Job 'nope' | Should -Be 2
    }
    It 'names the failed job in the final result line' {
        $env:DBBACKUP_FAKE_AGE_EXIT='1'
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 1
        $log = Get-ChildItem "$script:Root/instance/Logs" -File | Sort-Object LastWriteTimeUtc | Select-Object -Last 1
        (Get-Content $log.FullName | Select-Object -Last 1) | Should -Match 'RESULTADO: FALHA \(exit 1\) - jobs com falha: database'
    }
    It 'runs an instance that only backs up directories' {
        $source=Join-Path $script:Root 'documents'
        $null=New-Item -ItemType Directory $source
        Set-Content (Join-Path $source 'file.txt') 'document'
        $text = Get-Content $script:Config -Raw
        $text = $text -replace "(?m)^\s*Jobs = .*$", "    Jobs = @(@{ Id = 'documents'; Provider = 'Directory'; SourcePath = '$($source.Replace("'","''"))'; RemoteRoot = 's3:test-bucket' })"
        $text = $text -replace "(?m)^\s*(MySql|MySqlDump) = .*\r?\n", ''
        $text = $text.Replace("Jobs = @('database')", "Jobs = @('documents')")
        Set-Content $script:Config $text
        Remove-Item "$script:Root/instance/Secrets/mysql.cnf"
        Invoke-DBBackup -ConfigPath $script:Config -All | Should -Be 0
        @(Get-ChildItem "$script:Root/instance/Completed/documents" -Directory).Count | Should -Be 1
    }
}
