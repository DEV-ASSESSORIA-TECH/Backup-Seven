function New-DBTestFixture {
    param([string] $Root, [string] $Repository)
    $null = New-Item -ItemType Directory -Path $Root -Force
    $toolRoot = Join-Path $Root 'tools'
    $null = New-Item -ItemType Directory $toolRoot
    $exe = Join-Path $toolRoot 'fake.exe'
    & 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe' /nologo /target:exe "/out:$exe" (Join-Path $Repository 'tests/fixtures/V1FakeTool.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Fixture compilation failed.' }
    foreach ($name in @('mysql', 'mysqldump', '7z', 'age', 'rclone', 'dbbackup', 'dbvalid')) { Copy-Item $exe (Join-Path $toolRoot "$name.exe") }
    $config = Join-Path $Root 'instance/config.psd1'
    $null = New-Item -ItemType Directory (Join-Path $Root 'instance/Secrets') -Force
    $text = Get-Content (Join-Path $Repository 'src/Templates/MySQL/config.example.psd1') -Raw
    $map = @{MySql='mysql'; MySqlDump='mysqldump'; SevenZip='7z'; Age='age'; Rclone='rclone'}
    foreach ($key in $map.Keys) {
        $path = (Join-Path $toolRoot "$($map[$key]).exe").Replace("'", "''")
        $text = [regex]::Replace($text, "(?m)^(\s*$key\s*=\s*)'[^']*'", "`${1}'$path'")
    }
    $text = $text.Replace('s3:REPLACE_BUCKET', 's3:test-bucket').Replace('ReserveBytes = 1073741824','ReserveBytes = 0')
    Set-Content $config $text
    Set-Content (Join-Path $Root 'instance/Secrets/mysql.cnf') "[client]`nuser=test`npassword=fake-secret"
    Set-Content (Join-Path $Root 'instance/Secrets/rclone.conf') "[s3]`ntype=s3"
    Set-Content (Join-Path $Root 'instance/Secrets/recipients.txt') ('age1' + ('q' * 58))
    return $config
}

function Clear-DBTestEnvironment {
    Get-ChildItem Env:DBBACKUP_FAKE_* | ForEach-Object { Remove-Item -LiteralPath "Env:$($_.Name)" }
}
