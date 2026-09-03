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
            'config.example.psd1'
            'README.md'
            'VERSION'
            'Modules/Archive.psm1'
            'Modules/Database.psm1'
            'Modules/Fiscal.psm1'
            'Modules/Logging.psm1'
            'Modules/Storage.psm1'
        )

        @($script:Entries | Sort-Object) | Should -Be @($expectedEntries | Sort-Object)
    }

    It 'does not contain local configuration or development files' {
        $script:Entries | Should -Not -Contain 'config.psd1'
        $script:Entries | Should -Not -Contain 'ARCHITECTURE.md'
        $script:Entries | Should -Not -Contain 'CHANGELOG.md'
        @($script:Entries | Where-Object { $_ -like 'tests/*' }).Count | Should -Be 0
        @($script:Entries | Where-Object { $_ -like '.github/*' }).Count | Should -Be 0
    }
}
