BeforeAll {
    $script:Repo = Split-Path -Parent $PSScriptRoot
}
Describe 'DBBackup distribution' {
    BeforeAll {
        $script:Archive = & (Join-Path $script:Repo 'scripts/package.ps1') -OutputDirectory (Join-Path $TestDrive 'dist')
        $script:Zip = [IO.Compression.ZipFile]::OpenRead($script:Archive.FullName)
    }
    AfterAll { $script:Zip.Dispose() }
    It 'uses VERSION and a matching archive checksum' {
        $version = (Get-Content "$script:Repo/VERSION" -Raw).Trim()
        $script:Archive.Name | Should -Be "DBBackup-$version.zip"
        $checksum = (Get-Content "$($script:Archive.FullName).sha256" -Raw).Split(' ')[0]
        $checksum | Should -Be (Get-FileHash $script:Archive.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    It 'has exactly the approved list, never operational files or recovery tooling' {
        $list = @(Get-Content "$script:Repo/scripts/package.files.json" -Raw | ConvertFrom-Json)
        $actual = @($script:Zip.Entries | ForEach-Object {$_.FullName.Replace('\','/')} | Sort-Object)
        $expected = @(@($list.target) + 'PACKAGE-MANIFEST.json' | Sort-Object)
        $actual | Should -Be $expected
        $actual -join "`n" | Should -Not -Match '(^|/)(Secrets|Instances|Runtime|Completed|Logs)/|Restore\.ps1|Recovery\.ps1|\.exe$|\.log$'
        $actual | Should -Contain 'Modules/Core/Observation.psm1'
        $actual | Should -Contain 'Templates/SQLAnywhere/config.example.psd1'
    }
    It 'verifies each shipped file against the embedded manifest' {
        $reader = [IO.StreamReader]::new($script:Zip.GetEntry('PACKAGE-MANIFEST.json').Open())
        try { $manifest=$reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
        foreach ($entry in $script:Zip.Entries) {
            $name=$entry.FullName.Replace('\','/')
            if ($name -eq 'PACKAGE-MANIFEST.json') { continue }
            $stream=$entry.Open(); $sha=[Security.Cryptography.SHA256]::Create()
            try { [Convert]::ToHexString($sha.ComputeHash($stream)).ToLowerInvariant() | Should -Be $manifest.Files.$name }
            finally { $stream.Dispose(); $sha.Dispose() }
        }
    }
    It 'ships valid CRLF batch launchers pointing only to generic Setup.ps1' {
        foreach ($name in @('Setup.bat','Aplicar-Configuracao.bat')) {
            $reader=[IO.StreamReader]::new($script:Zip.GetEntry($name).Open())
            try { $text=$reader.ReadToEnd() } finally { $reader.Dispose() }
            $text | Should -Match 'Setup.ps1'
            $text | Should -Match '\r\n'
            $text | Should -Not -Match '(?<!\r)\n|BackupSeven|Backup-Seven'
        }
    }
    It 'loads entrypoints and provider modules from the extracted package' {
        $root=Join-Path $TestDrive 'extracted'
        [IO.Compression.ZipFile]::ExtractToDirectory($script:Archive.FullName,$root)
        foreach ($name in @('Backup.ps1','Setup.ps1','Diagnose.ps1')) {
            $null=Get-Command (Join-Path $root $name) -ErrorAction Stop
        }
        # Parse/import in a separate process: no provider/diagnostic is invoked.
        $exe=(Get-Process -Id $PID).Path
        & $exe -NoProfile -Command '& { param($root) Import-Module (Join-Path $root "Modules/Core/Runner.psm1"); Import-Module (Join-Path $root "Modules/Providers/Providers.psm1"); }' $root
        $LASTEXITCODE | Should -Be 0
    }
}
