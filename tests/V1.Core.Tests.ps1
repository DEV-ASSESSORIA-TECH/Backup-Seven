BeforeAll {
    $script:Repo = Split-Path -Parent $PSScriptRoot
    Import-Module "$script:Repo/src/Modules/Core/Configuration.psm1"
    Import-Module "$script:Repo/src/Modules/Core/Runtime.psm1"
}
Describe 'DBBackup v1 instance configuration' {
    BeforeEach {
        $script:Config = Join-Path $TestDrive 'instance/config.psd1'
        $null = New-Item -ItemType Directory -Path (Split-Path $script:Config) -Force
        Copy-Item "$script:Repo/src/Templates/MySQL/config.example.psd1" $script:Config
    }
    It 'resolves paths relative to the configuration' {
        $c = Read-DBConfiguration $script:Config
        $c.Paths.RuntimeRoot | Should -Be (Join-Path (Split-Path $script:Config) 'Runtime')
        $c.Jobs.Id | Should -Contain 'database'
    }
    It 'rejects incompatible configuration and overlapping state' {
        $text = Get-Content $script:Config -Raw
        Set-Content $script:Config ($text.Replace('SchemaVersion = 1', 'SchemaVersion = 0'))
        { Read-DBConfiguration $script:Config } | Should -Throw '*SchemaVersion*'
        Set-Content $script:Config ($text.Replace("CompletedRoot = 'Completed'", "CompletedRoot = 'Runtime/Completed'"))
        { Read-DBConfiguration $script:Config } | Should -Throw '*overlap*'
    }
    It 'rejects directory sources that include the instance' {
        $text = (Get-Content $script:Config -Raw).Replace('Directories = @()', "Directories = @(@{Id='files'; SourcePath='..'})")
        Set-Content $script:Config $text
        { Read-DBConfiguration $script:Config } | Should -Throw '*overlap*'
    }
    It 'rejects cross-volume Completed to preserve atomic bundle transitions' {
        $currentRoot=[IO.Path]::GetPathRoot($TestDrive)
        $otherRoot=if ($currentRoot -eq 'Z:\') {'Y:\DBBackupCompleted'} else {'Z:\DBBackupCompleted'}
        Set-Content $script:Config ((Get-Content $script:Config -Raw).Replace("CompletedRoot = 'Completed'", "CompletedRoot = '$otherRoot'"))
        { Read-DBConfiguration $script:Config } | Should -Throw '*same volume*'
    }
    It 'locks only the selected instance' {
        Mock Set-Acl {} -ModuleName Runtime
        $c = Read-DBConfiguration $script:Config
        $r = New-DBRuntime $c
        try {
            New-DBRuntime $c | Should -BeNullOrEmpty
            $other = Join-Path $TestDrive 'other/config.psd1'
            $null = New-Item -ItemType Directory (Split-Path $other)
            Copy-Item $script:Config $other
            $second = New-DBRuntime (Read-DBConfiguration $other)
            try { $second | Should -Not -BeNullOrEmpty } finally { Close-DBRuntime $second }
        }
        finally { Close-DBRuntime $r }
    }
    It 'redacts connection passwords including spaces' {
        Protect-DBMessage 'PWD="secret phrase";password=hidden' | Should -Be 'PWD=[REDACTED];password=[REDACTED]'
    }
    It 'rejects state inside another instance Secrets directory' {
        $other = Join-Path $TestDrive 'other/config.psd1'
        $null = New-Item -ItemType Directory (Split-Path $other) -Force
        $text = (Get-Content $script:Config -Raw).Replace("InstanceName = 'MySQL'", "InstanceName = 'Other'")
        Set-Content $other $text
        $foreign = (Join-Path (Split-Path $other) 'Secrets/private-state').Replace("'", "''")
        Set-Content $script:Config ((Get-Content $script:Config -Raw).Replace("RuntimeRoot = 'Runtime'", "RuntimeRoot = '$foreign'"))
        { Assert-DBInstanceIsolation (Read-DBConfiguration $script:Config) $TestDrive } | Should -Throw '*share*'
    }
    It 'validates run deadline, local payload retention and destination label' {
        $text = Get-Content $script:Config -Raw
        (Read-DBConfiguration $script:Config).Execution.RunTimeoutSeconds | Should -Be 39600
        Set-Content $script:Config ($text.Replace('RunTimeoutSeconds = 39600', 'RunTimeoutSeconds = 60'))
        { Read-DBConfiguration $script:Config } | Should -Throw '*RunTimeoutSeconds*'
        Set-Content $script:Config ($text.Replace('KeepLocalPayload = $true', "KeepLocalPayload = 'no'"))
        { Read-DBConfiguration $script:Config } | Should -Throw '*KeepLocalPayload*'
        Set-Content $script:Config ($text.Replace("Destination = 's3'", "Destination = 'S3 Bucket'"))
        { Read-DBConfiguration $script:Config } | Should -Throw '*Destination*'
        Set-Content $script:Config ($text.Replace("; Destination = 's3'", '').Replace('; KeepLocalPayload = $true', ''))
        $c = Read-DBConfiguration $script:Config
        $c.Storage.Destination | Should -Be 's3'
        $c.Retention.KeepLocalPayload | Should -BeTrue
    }
    It 'removes only generated stale Work and Staging entries' {
        $runtime = Join-Path $TestDrive 'stale-runtime'
        $current = 'c' * 32
        foreach ($dir in @("Work/$current/db", "Work/$('d' * 32)/db", 'Work/manual', 'Staging/DBBackup_x_FULL', 'Staging/other', 'Pending/database/DBBackup_y')) {
            $null = New-Item -ItemType Directory (Join-Path $runtime $dir) -Force
        }
        $r = [pscustomobject]@{ RunId = $current; Work = (Join-Path $runtime "Work/$current"); Staging = (Join-Path $runtime 'Staging'); Pending = (Join-Path $runtime 'Pending') }
        $result = Clear-DBStaleRuntime $r
        @($result.Removed).Count | Should -Be 2
        @($result.Skipped).Count | Should -Be 2
        Test-Path (Join-Path $runtime "Work/$current/db") | Should -BeTrue
        Test-Path (Join-Path $runtime "Work/$('d' * 32)") | Should -BeFalse
        Test-Path (Join-Path $runtime 'Staging/DBBackup_x_FULL') | Should -BeFalse
        Test-Path (Join-Path $runtime 'Work/manual') | Should -BeTrue
        Test-Path (Join-Path $runtime 'Staging/other') | Should -BeTrue
        Test-Path (Join-Path $runtime 'Pending/database/DBBackup_y') | Should -BeTrue
    }
    It 'never rewrites permissions of an existing populated directory during a run' -Skip:(-not $IsWindows) {
        Mock Set-Acl {} -ModuleName Runtime
        Mock Test-DBPrivateAccess { $false } -ModuleName Runtime
        $shared = Join-Path $TestDrive 'shared-logs'
        $null = New-Item -ItemType Directory $shared
        Set-Content (Join-Path $shared 'other-app.log') 'foreign'
        Set-DBPrivateDirectory $shared
        Should -Invoke Set-Acl -ModuleName Runtime -Times 0 -Exactly
        { Set-DBPrivateDirectory $shared -Enforce } | Should -Throw '*not private*'
        Should -Invoke Set-Acl -ModuleName Runtime -Times 0 -Exactly
        Set-DBPrivateDirectory $shared -Force
        Should -Invoke Set-Acl -ModuleName Runtime -Times 1 -Exactly
        $empty = Join-Path $TestDrive 'empty-state'
        $null = New-Item -ItemType Directory $empty
        Set-DBPrivateDirectory $empty -Enforce
        Should -Invoke Set-Acl -ModuleName Runtime -Times 2 -Exactly
        Set-DBPrivateDirectory (Join-Path $TestDrive 'brand-new')
        Should -Invoke Set-Acl -ModuleName Runtime -Times 3 -Exactly
    }
    It 'treats RemoteRoot as the complete destination and rejects unsafe prefixes' {
        ConvertTo-DBRemoteRoot 's3:bucket/ASSESSORIA/' | Should -BeExactly 's3:bucket/ASSESSORIA'
        ConvertTo-DBRemoteRoot 's3:bucket' | Should -BeExactly 's3:bucket'
        { ConvertTo-DBRemoteRoot 's3:' } | Should -Throw '*bucket*'
        { ConvertTo-DBRemoteRoot 's3:bucket/../other' } | Should -Throw '*invalid path segment*'
        { ConvertTo-DBRemoteRoot 's3:bucket//x' } | Should -Throw '*invalid path segment*'
        Test-DBRemoteOverlap 's3:b/ASSESSORIA' 's3:b/ASSESSORIA' | Should -BeTrue
        Test-DBRemoteOverlap 's3:b/ASSESSORIA' 's3:b/ASSESSORIA/sub' | Should -BeTrue
        Test-DBRemoteOverlap 's3:b/ASSESSORIA' 's3:b/assessoria' | Should -BeFalse
        Test-DBRemoteOverlap 's3:b/ASSESSORIA' 's3:b/ASSESSORIA-2' | Should -BeFalse
    }
    It 'refuses two instances writing to the same destination prefix' {
        $other = Join-Path $TestDrive 'other/config.psd1'
        $null = New-Item -ItemType Directory (Split-Path $other) -Force
        $text = (Get-Content $script:Config -Raw).Replace('s3:REPLACE_BUCKET', 's3:bucket/ASSESSORIA')
        Set-Content $other $text.Replace("InstanceName = 'MySQL'", "InstanceName = 'Other'")
        Set-Content $script:Config $text
        { Assert-DBInstanceIsolation (Read-DBConfiguration $script:Config) $TestDrive } | Should -Throw '*remote destination*'
        Set-Content $script:Config $text.Replace('s3:bucket/ASSESSORIA', 's3:bucket/MULTI-COPIAS')
        { Assert-DBInstanceIsolation (Read-DBConfiguration $script:Config) $TestDrive } | Should -Not -Throw
    }
}
