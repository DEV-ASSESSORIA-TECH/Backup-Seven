BeforeAll {
    $script:Repo = Split-Path -Parent $PSScriptRoot
    $script:Updater = Join-Path $script:Repo 'src/App/Update.ps1'
    $script:Version = [version] (Get-Content (Join-Path $script:Repo 'VERSION') -Raw).Trim()
    $script:Package = & (Join-Path $script:Repo 'scripts/package.ps1') -OutputDirectory (Join-Path $TestDrive 'dist')
    $script:Pwsh = (Get-Process -Id $PID).Path

    function New-TestInstallation {
        <# A 2.0.0 installation with operational state and a module removed in the new version. #>
        param([string] $Name)
        $root = Join-Path $TestDrive $Name
        [IO.Compression.ZipFile]::ExtractToDirectory($script:Package.FullName, $root)
        Set-Content -LiteralPath (Join-Path $root 'App/VERSION') -Value '2.0.0'
        Set-Content -LiteralPath (Join-Path $root 'App/Modules/Core/Removed.psm1') -Value 'old'
        Set-Content -LiteralPath (Join-Path $root 'DBBackup.bat') -Value 'old launcher'
        foreach ($path in @('Instances/acme/Secrets', 'Instances/acme/Runtime', 'Completed/acme/db', 'Logs/acme')) { $null = New-Item -ItemType Directory -Path (Join-Path $root $path) -Force }
        Set-Content -LiteralPath (Join-Path $root 'Instances/acme/config.psd1') -Value '@{ InstanceName = ''acme'' }'
        Set-Content -LiteralPath (Join-Path $root 'Instances/acme/Secrets/rclone.conf') -Value 'secret'
        Set-Content -LiteralPath (Join-Path $root 'Completed/acme/db/bundle.age') -Value 'payload'
        Set-Content -LiteralPath (Join-Path $root 'Logs/acme/run.log') -Value 'log'
        return $root
    }

    function Get-TestState {
        param([string] $Root)
        return @(Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object { $_.FullName -match '[\\/](Instances|Completed|Logs)[\\/]' } |
            ForEach-Object { '{0}={1}' -f [IO.Path]::GetRelativePath($Root, $_.FullName), (Get-FileHash -LiteralPath $_.FullName).Hash } | Sort-Object)
    }

    function Invoke-TestUpdater {
        param([string] $Root, [string] $Zip)
        & $script:Pwsh -NoProfile -File $script:Updater -InstallRoot $Root -PackagePath $Zip -Yes *>&1 | Out-String
    }
}

Describe 'DBBackup updater (DBBackup.bat, opcao 8)' {
    It 'is shipped with a launcher that runs a temporary copy and keeps the rest of the bat in one block' {
        $list = @(Get-Content (Join-Path $script:Repo 'scripts/package.files.json') -Raw | ConvertFrom-Json)
        $list.target | Should -Contain 'DBBackup.bat'
        $list.target | Should -Contain 'App/Update.ps1'
        $bat = [IO.File]::ReadAllText((Join-Path $script:Repo 'src/DBBackup.bat'))
        $bat | Should -Match '(?s)\(\r\n\s+copy /y "%~dp0App\\Update\.ps1" "%DBBACKUP_UPDATER%".*-File "%DBBACKUP_UPDATER%" -InstallRoot "%~dp0\." -PackagePath "%DBBACKUP_PACKAGE%".*call "%~f0"\r\n\s+exit /b\r\n\)\r\n$'
        $bat | Should -Not -Match '(?<!\r)\n'
    }

    It 'parses release versions strictly' {
        . $script:Updater
        ConvertTo-DBReleaseVersion 'v2.1.0' | Should -Be ([version] '2.1.0')
        ConvertTo-DBReleaseVersion "2.0.0`r`n" | Should -Be ([version] '2.0.0')
        { ConvertTo-DBReleaseVersion 'v2.1' } | Should -Throw
        { ConvertTo-DBReleaseVersion '2.1.0-beta' } | Should -Throw
    }

    It 'replaces App and the launchers from a local package and keeps Instances, Completed and Logs' {
        $root = New-TestInstallation 'offline'
        $before = Get-TestState $root
        $output = Invoke-TestUpdater $root $script:Package.FullName
        $LASTEXITCODE | Should -Be 0 -Because $output
        (Get-Content (Join-Path $root 'App/VERSION') -Raw).Trim() | Should -Be ([string] $script:Version)
        Join-Path $root 'App/Modules/Core/Removed.psm1' | Should -Not -Exist
        Join-Path $root 'App/Update.ps1' | Should -Exist
        (Get-Content (Join-Path $root 'DBBackup.bat') -Raw) | Should -Match 'App\\Menu\.ps1'
        Get-TestState $root | Should -Be $before
        $previous = @(Get-ChildItem (Join-Path $root 'Versoes-Anteriores') -Directory)
        $previous.Count | Should -Be 1
        $previous[0].Name | Should -Match '^2\.0\.0_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$'
        (Get-Content (Join-Path $previous[0].FullName 'App/VERSION') -Raw).Trim() | Should -Be '2.0.0'
        Join-Path $previous[0].FullName 'App/Modules/Core/Removed.psm1' | Should -Exist
        (Get-Content (Join-Path $previous[0].FullName 'DBBackup.bat') -Raw).Trim() | Should -Be 'old launcher'
        $output | Should -Match 'Checksum do pacote conferido'
    }

    It 'changes nothing when the package checksum does not match' {
        $root = New-TestInstallation 'badsum'
        $zip = Join-Path $TestDrive 'badsum.zip'
        Copy-Item $script:Package.FullName $zip
        Set-Content -LiteralPath "$zip.sha256" -Value ('0' * 64 + '  badsum.zip')
        $output = Invoke-TestUpdater $root $zip
        $LASTEXITCODE | Should -Be 1
        $output | Should -Match 'Checksum do pacote nao confere'
        (Get-Content (Join-Path $root 'App/VERSION') -Raw).Trim() | Should -Be '2.0.0'
        Join-Path $root 'Versoes-Anteriores' | Should -Not -Exist
    }

    It 'refuses a ZIP that carries operational state or is not a DBBackup package' {
        $root = New-TestInstallation 'unsafe'
        $source = Join-Path $TestDrive 'unsafe-src'
        [IO.Compression.ZipFile]::ExtractToDirectory($script:Package.FullName, $source)
        $null = New-Item -ItemType Directory -Path (Join-Path $source 'Instances/acme') -Force
        Set-Content -LiteralPath (Join-Path $source 'Instances/acme/config.psd1') -Value 'overwrite'
        $zip = Join-Path $TestDrive 'unsafe.zip'
        [IO.Compression.ZipFile]::CreateFromDirectory($source, $zip)
        $output = Invoke-TestUpdater $root $zip
        $LASTEXITCODE | Should -Be 1
        $output | Should -Match 'item inesperado na raiz: Instances'
        (Get-Content (Join-Path $root 'Instances/acme/config.psd1') -Raw) | Should -Match 'acme'

        $other = Join-Path $TestDrive 'other-src'
        $null = New-Item -ItemType Directory -Path (Join-Path $other 'App') -Force
        Set-Content -LiteralPath (Join-Path $other 'App/VERSION') -Value '9.9.9'
        $otherZip = Join-Path $TestDrive 'other.zip'
        [IO.Compression.ZipFile]::CreateFromDirectory($other, $otherZip)
        $output = Invoke-TestUpdater $root $otherZip
        $LASTEXITCODE | Should -Be 1
        $output | Should -Match 'nao e um pacote do DBBackup'
        (Get-Content (Join-Path $root 'App/VERSION') -Raw).Trim() | Should -Be '2.0.0'
    }

    It 'does not update while a backup holds an instance lock' {
        $root = New-TestInstallation 'busy'
        $lock = [IO.File]::Open((Join-Path $root 'Instances/acme/Runtime/DBBackup.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        try { $output = Invoke-TestUpdater $root $script:Package.FullName; $code = $LASTEXITCODE }
        finally { $lock.Dispose() }
        $code | Should -Be 3
        $output | Should -Match 'Backup em execucao nas instancias: acme'
        (Get-Content (Join-Path $root 'App/VERSION') -Raw).Trim() | Should -Be '2.0.0'
        . $script:Updater
        @(Get-DBRunningInstance $root) | Should -BeNullOrEmpty
    }

    It 'restores the previous version when the replacement fails' {
        . $script:Updater
        $root = New-TestInstallation 'rollback'
        $staging = Join-Path $TestDrive 'rollback-staging'
        [IO.Compression.ZipFile]::ExtractToDirectory($script:Package.FullName, $staging)
        Mock Copy-DBDirectory -ParameterFilter { $Source -like '*rollback-staging*' } { throw 'disk full' }
        { Install-DBUpdate -InstallRoot $root -Staging $staging -CurrentVersion ([version] '2.0.0') } | Should -Throw '*versao 2.0.0 foi restaurada*disk full*'
        (Get-Content (Join-Path $root 'App/VERSION') -Raw).Trim() | Should -Be '2.0.0'
        Join-Path $root 'App/Modules/Core/Removed.psm1' | Should -Exist
        (Get-Content (Join-Path $root 'DBBackup.bat') -Raw).Trim() | Should -Be 'old launcher'
    }

    It 'keeps only the three newest previous versions' {
        . $script:Updater
        $root = Join-Path $TestDrive 'prune'
        $previous = Join-Path $root 'Versoes-Anteriores'
        $names = @('1.0.0_2026-01-01_00-00-00', '1.1.0_2026-02-01_00-00-00', '2.0.0_2026-03-01_00-00-00', '2.0.1_2026-04-01_00-00-00', 'manual')
        for ($i = 0; $i -lt $names.Count; $i++) {
            $item = New-Item -ItemType Directory -Path (Join-Path $previous $names[$i]) -Force
            $item.LastWriteTimeUtc = [DateTime]::UtcNow.AddDays($i - 10)
        }
        Remove-DBOldPreviousVersion -InstallRoot $root
        @(Get-ChildItem $previous -Directory | ForEach-Object Name | Sort-Object) | Should -Be @('1.1.0_2026-02-01_00-00-00', '2.0.0_2026-03-01_00-00-00', '2.0.1_2026-04-01_00-00-00', 'manual')
    }

    Context 'GitHub latest release' {
        BeforeAll {
            . $script:Updater
            $script:Release = {
                param([string] $Tag)
                [pscustomobject]@{
                    tag_name = $Tag; html_url = "https://github.com/x/y/releases/tag/$Tag"
                    assets = @(
                        [pscustomobject]@{ name = "DBBackup-$($Tag.TrimStart('v')).zip"; browser_download_url = 'https://example.invalid/zip' }
                        [pscustomobject]@{ name = "DBBackup-$($Tag.TrimStart('v')).zip.sha256"; browser_download_url = 'https://example.invalid/sha' }
                    )
                }
            }
        }

        It 'does nothing when the installed version is already the latest' {
            $InstallRoot = New-TestInstallation 'current'
            Set-Content -LiteralPath (Join-Path $InstallRoot 'App/VERSION') -Value ([string] $script:Version)
            Mock Invoke-RestMethod { & $script:Release "v$($script:Version)" }
            Mock Invoke-WebRequest { throw 'must not download' }
            Invoke-DBUpdate -InstallRoot $InstallRoot -Yes 6>&1 | Out-Null
            Should -Invoke Invoke-WebRequest -Times 0
        }

        It 'downloads, verifies and installs a newer release' {
            $InstallRoot = New-TestInstallation 'online'
            Mock Invoke-RestMethod { & $script:Release "v$($script:Version)" } -ParameterFilter { $Uri -eq 'https://api.github.com/repos/DEV-ASSESSORIA-TECH/DBBackup/releases/latest' }
            Mock Invoke-WebRequest {
                $source = if ($Uri -like '*sha') { "$($script:Package.FullName).sha256" } else { $script:Package.FullName }
                Copy-Item -LiteralPath $source -Destination $OutFile
            }
            Invoke-DBUpdate -InstallRoot $InstallRoot -Yes | Should -Be 0
            Should -Invoke Invoke-WebRequest -Times 2
            (Get-Content (Join-Path $InstallRoot 'App/VERSION') -Raw).Trim() | Should -Be ([string] $script:Version)
            Join-Path $InstallRoot 'Instances/acme/Secrets/rclone.conf' | Should -Exist
        }

        It 'rejects a release without the expected assets' {
            Mock Invoke-RestMethod { [pscustomobject]@{ tag_name = 'v9.0.0'; html_url = 'x'; assets = @() } }
            { Get-DBLatestRelease -Repository 'a/b' -ApiBaseUrl 'https://api.github.com' } | Should -Throw '*DBBackup-9.0.0.zip*'
        }
    }
}
