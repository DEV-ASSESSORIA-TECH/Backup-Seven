Describe 'Production package' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("BackupSeven-package-test-$([guid]::NewGuid().ToString('N'))")
        $script:OutputRoot = Join-Path $script:TestRoot 'dist'
        $script:PackageScript = Join-Path $script:RepositoryRoot 'scripts/package.ps1'
        $script:Archive = & $script:PackageScript -OutputDirectory $script:OutputRoot
        $script:Zip = [System.IO.Compression.ZipFile]::OpenRead($script:Archive.FullName)
        $script:Entries = @($script:Zip.Entries | Where-Object { -not $_.FullName.EndsWith('/') } | ForEach-Object { $_.FullName })
    }

    AfterAll {
        if ($null -ne $script:Zip) {
            $script:Zip.Dispose()
        }

        if (Test-Path -LiteralPath $script:TestRoot) {
            Remove-Item -LiteralPath $script:TestRoot -Recurse -Force
        }
    }

    It 'uses VERSION in the archive name' {
        $version = (Get-Content (Join-Path $script:RepositoryRoot 'VERSION') -Raw).Trim()
        $script:Archive.Name | Should -Be "BackupSeven-$version.zip"
    }

    It 'creates a valid SHA256 file beside the archive' {
        $checksumPath = "$($script:Archive.FullName).sha256"
        Test-Path -LiteralPath $checksumPath -PathType Leaf | Should -BeTrue

        $recordedHash = ((Get-Content -LiteralPath $checksumPath -Raw).Trim() -split '\s+')[0]
        $actualHash = (Get-FileHash -LiteralPath $script:Archive.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $recordedHash | Should -Be $actualHash
    }

    It 'contains only the production allowlist' {
        $expectedEntries = @(
            'Backup-Seven.ps1'
            'config.psd1'
            'README.md'
            'Secrets/mysql-backup.cnf'
            'Secrets/rclone.conf'
            'VERSION'
            'Modules/Archive.psm1'
            'Modules/Database.psm1'
            'Modules/Fiscal.psm1'
            'Modules/Logging.psm1'
            'Modules/Storage.psm1'
        )

        @($script:Entries | Sort-Object) | Should -Be @($expectedEntries | Sort-Object)
    }

    It 'ships editable templates under their production names' {
        $configEntry = $script:Zip.GetEntry('config.psd1')
        $mysqlEntry = $script:Zip.GetEntry('Secrets/mysql-backup.cnf')
        $rcloneEntry = $script:Zip.GetEntry('Secrets/rclone.conf')

        $configReader = [System.IO.StreamReader]::new($configEntry.Open())
        $mysqlReader = [System.IO.StreamReader]::new($mysqlEntry.Open())
        $rcloneReader = [System.IO.StreamReader]::new($rcloneEntry.Open())
        try {
            $configContent = $configReader.ReadToEnd()
            $mysqlContent = $mysqlReader.ReadToEnd()
            $rcloneContent = $rcloneReader.ReadToEnd()
        }
        finally {
            $configReader.Dispose()
            $mysqlReader.Dispose()
            $rcloneReader.Dispose()
        }

        $configContent | Should -Match "InstanceName = 'MULTI-COPIAS'"
        $configContent | Should -Match "Name = 'a_estoque'"
        $mysqlContent | Should -Match '^\[client\]'
        $mysqlContent | Should -Match 'password=REPLACE_WITH_BACKUP_PASSWORD'
        $rcloneContent | Should -Match '^\[s3\]'
        $rcloneContent | Should -Match 'access_key_id = REPLACE_WITH_AWS_ACCESS_KEY_ID'
        $rcloneContent | Should -Match 'secret_access_key = REPLACE_WITH_AWS_SECRET_ACCESS_KEY'
        $rcloneContent | Should -Match 'region = sa-east-1'
    }

    It 'does not contain source templates, local secrets or development files' {
        $script:Entries | Should -Not -Contain 'config.example.psd1'
        $script:Entries | Should -Not -Contain 'Secrets/mysql-backup.example.cnf'
        $script:Entries | Should -Not -Contain 'Secrets/rclone.example.conf'
        $script:Entries | Should -Not -Contain 'ARCHITECTURE.md'
        $script:Entries | Should -Not -Contain 'CHANGELOG.md'
        @($script:Entries | Where-Object { $_ -like 'tests/*' }).Count | Should -Be 0
        @($script:Entries | Where-Object { $_ -like '.github/*' }).Count | Should -Be 0
    }
}
