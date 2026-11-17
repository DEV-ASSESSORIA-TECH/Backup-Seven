BeforeAll {
    $script:Repo = Split-Path -Parent $PSScriptRoot
    Import-Module "$script:Repo/src/Modules/Core/Configuration.psm1" -Force
    Import-Module "$script:Repo/src/Modules/Core/Runtime.psm1" -Force
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
}
