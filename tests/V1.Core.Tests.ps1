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
}
