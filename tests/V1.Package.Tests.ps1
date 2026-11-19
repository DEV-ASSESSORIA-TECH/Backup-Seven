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
    It 'has exactly the approved list: launchers and LEIA-ME at the root, scripts under App' {
        $list = @(Get-Content "$script:Repo/scripts/package.files.json" -Raw | ConvertFrom-Json)
        $actual = @($script:Zip.Entries | ForEach-Object {$_.FullName.Replace('\','/')} | Sort-Object)
        $expected = @(@($list.target) + 'LEIA-ME.txt' | Sort-Object)
        $actual | Should -Be $expected
        $actual -join "`n" | Should -Not -Match '(^|/)(Secrets|Instances|Runtime|Completed|Logs)/|Restore\.ps1|Recovery\.ps1|\.exe$|\.log$'
        $actual -join "`n" | Should -Not -Match '(?i)README|RUNBOOK|ARCHITECTURE|CHANGELOG|contracts/|PACKAGE-MANIFEST'
        @($actual | Where-Object { $_ -notmatch '/' } | Sort-Object) | Should -Be @('Aplicar-Configuracao.bat','Atualizar.bat','Diagnosticar.bat','Editar-Configuracao.bat','Executar-Backup.bat','LEIA-ME.txt','Setup.bat')
        $actual | Should -Contain 'App/VERSION'
        $actual | Should -Contain 'App/Modules/Core/Observation.psm1'
        $actual | Should -Contain 'App/Templates/config.example.psd1'
    }
    It 'ships a LEIA-ME with the installed version and repository links' {
        $version = (Get-Content "$script:Repo/VERSION" -Raw).Trim()
        $reader=[IO.StreamReader]::new($script:Zip.GetEntry('LEIA-ME.txt').Open())
        try { $text=$reader.ReadToEnd() } finally { $reader.Dispose() }
        $text | Should -Match "Versao instalada: $([regex]::Escape($version))"
        $text | Should -Match ([regex]::Escape("https://github.com/DEV-ASSESSORIA-TECH/DBBackup/tree/v$version"))
        $text | Should -Not -Match '\{\{VERSION\}\}'
        $text | Should -Not -Match '(?<!\r)\n'
    }
    It 'ships valid CRLF batch launchers pointing to the scripts under App' {
        $map=@{ 'Setup.bat'='App\\Setup.ps1'; 'Aplicar-Configuracao.bat'='App\\Setup.ps1" -Apply'; 'Editar-Configuracao.bat'='App\\Setup.ps1" -Edit'; 'Diagnosticar.bat'='App\\Diagnose.ps1'; 'Executar-Backup.bat'='App\\Backup.ps1" -Interactive'; 'Atualizar.bat'='App\\Update.ps1' }
        foreach ($name in $map.Keys) {
            $reader=[IO.StreamReader]::new($script:Zip.GetEntry($name).Open())
            try { $text=$reader.ReadToEnd() } finally { $reader.Dispose() }
            $text | Should -Match ([regex]::Escape($map[$name]).Replace('\\\\','\\'))
            $text | Should -Match '\r\n'
            $text | Should -Not -Match '(?<!\r)\n|BackupSeven|Backup-Seven'
        }
    }
    It 'loads entrypoints and provider modules from the extracted package' {
        $root=Join-Path $TestDrive 'extracted'
        [IO.Compression.ZipFile]::ExtractToDirectory($script:Archive.FullName,$root)
        foreach ($name in @('Backup.ps1','Setup.ps1','Diagnose.ps1','Update.ps1')) {
            $null=Get-Command (Join-Path $root "App/$name") -ErrorAction Stop
        }
        # Parse/import in a separate process: no provider/diagnostic is invoked.
        $exe=(Get-Process -Id $PID).Path
        & $exe -NoProfile -Command '& { param($root) Import-Module (Join-Path $root "App/Modules/Core/Runner.psm1"); Import-Module (Join-Path $root "App/Modules/Providers/Providers.psm1"); Import-Module (Join-Path $root "App/Modules/Core/Observation.psm1"); if ((Get-DBApplicationVersion) -ne (Get-Content (Join-Path $root "App/VERSION") -Raw).Trim()) { exit 9 } }' $root
        $LASTEXITCODE | Should -Be 0
    }
}
