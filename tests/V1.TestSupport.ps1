function Get-DBTestConfigText {
    <#
    Schema 2 test configuration: one MySQL job 'database'. Paths stay inside
    the instance so tests can inspect Completed/Logs next to config.psd1.
    Tests add jobs by replacing the 'Jobs = @(' marker.
    #>
    param([hashtable] $Tools = @{}, [string] $RemoteRoot = 's3:REPLACE_BUCKET', [string] $InstanceName = 'MySQL')
    $defaults = @{ MySql = 'C:\Program Files\MySQL\MySQL Server 5.5\bin\mysql.exe'; MySqlDump = 'C:\Program Files\MySQL\MySQL Server 5.5\bin\mysqldump.exe'
        SevenZip = 'C:\Program Files\7-Zip\7z.exe'; Age = 'C:\Program Files\age\age.exe'; Rclone = 'C:\Program Files\rclone\rclone.exe' }
    foreach ($key in $Tools.Keys) { $defaults[$key] = $Tools[$key] }
    $toolLines = ($defaults.GetEnumerator() | Sort-Object Key | ForEach-Object { "        $($_.Key) = '$($_.Value.Replace("'", "''"))'" }) -join "`n"
    @"
@{
    SchemaVersion = 2
    InstanceName = '$InstanceName'
    Tools = @{
$toolLines
    }
    Jobs = @(@{ Id = 'database'; Provider = 'MySQL'; Database = 'testdb'; CredentialFile = 'Secrets/mysql.cnf'; ExtraArguments = @('--skip-events'); RemoteRoot = '$RemoteRoot' })
    Execution = @{ ToolTimeoutSeconds = 21600; RunTimeoutSeconds = 39600; ReserveBytes = 0; EstimatedDatabaseBytes = 0 }
    Storage = @{ ConfigPath = 'Secrets/rclone.conf'; Destination = 's3' }
    Encryption = @{ RecipientsFile = 'Secrets/recipients.txt' }
    Paths = @{ RuntimeRoot = 'Runtime'; CompletedRoot = 'Completed'; LogRoot = 'Logs' }
    Archive = @{ CompressionLevel = 5; CpuLimitPercent = 50 }
    Retention = @{ CompletedDays = 7; LogDays = 30; KeepLocalPayload = `$true }
    Monitoring = @{ Enabled = `$false; Service = 'erp'; TextfileDirectory = 'C:\ProgramData\GrafanaLabs\Alloy\textfile\backup'; BackupIds = @{} }
    Schedule = @{ Tasks = @(@{ Name = 'database-daily'; Jobs = @('database'); At = '19:00'; Frequency = 'Daily'; Enabled = `$true }) }
}
"@
}

function Add-DBTestJob {
    <# Inserts a job hashtable literal before the existing jobs of a test config. #>
    param([string] $ConfigPath, [string] $JobLiteral)
    Set-Content $ConfigPath ((Get-Content $ConfigPath -Raw).Replace('Jobs = @(', "Jobs = @($JobLiteral, "))
}

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
    $tools = @{}
    foreach ($entry in @{MySql='mysql'; MySqlDump='mysqldump'; SevenZip='7z'; Age='age'; Rclone='rclone'; DbBackup='dbbackup'}.GetEnumerator()) {
        $tools[$entry.Key] = Join-Path $toolRoot "$($entry.Value).exe"
    }
    Set-Content $config (Get-DBTestConfigText -Tools $tools -RemoteRoot 's3:test-bucket')
    Set-Content (Join-Path $Root 'instance/Secrets/mysql.cnf') "[client]`nuser=test`npassword=fake-secret"
    Set-Content (Join-Path $Root 'instance/Secrets/rclone.conf') "[s3]`ntype=s3"
    Set-Content (Join-Path $Root 'instance/Secrets/recipients.txt') ('age1' + ('q' * 58))
    return $config
}

function Clear-DBTestEnvironment {
    Get-ChildItem Env:DBBACKUP_FAKE_* | ForEach-Object { Remove-Item -LiteralPath "Env:$($_.Name)" }
}
