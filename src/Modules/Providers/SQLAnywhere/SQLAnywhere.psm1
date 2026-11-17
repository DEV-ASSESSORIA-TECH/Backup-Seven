Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../../Core/Process.psm1')
Import-Module (Join-Path $PSScriptRoot '../../Core/Runtime.psm1')

function Read-DBSqlConnection {
    param([string] $Path)
    $text = (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop).Trim()
    # One connection option only; no nested response files, output redirects,
    # server-side backup, log rotation, truncation, or arbitrary utility flags.
    if ($text -notmatch '\A-c\s+"([^"\r\n]+)"\z') { throw 'SQL options must contain exactly -c "<connection>" on one line.' }
    $builder = [Data.Common.DbConnectionStringBuilder]::new()
    try { $builder.set_ConnectionString($Matches[1]) }
    catch { throw 'SQL connection string could not be parsed.' }
    $values = @{}
    foreach ($key in $builder.Keys) {
        if ($key.ToUpperInvariant() -notin @('UID','PWD','HOST','DBN','SERVER','CHARSET')) { throw "Unsupported SQL connection parameter: $key" }
        $value = [string] $builder[$key]
        if ($value -match '["\r\n]') { throw 'SQL connection values cannot contain double quotes or newlines.' }
        $values[$key.ToUpperInvariant()] = $value
    }
    foreach ($key in @('UID','PWD','HOST','DBN')) {
        if (-not $values.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($values[$key])) { throw "SQL connection parameter is required: $key" }
    }
    return $values
}

function ConvertTo-DBSqlConnection {
    param([Collections.IDictionary] $Values)
    return (($Values.Keys | Sort-Object | ForEach-Object {
        '{0}=''{1}''' -f $_, ([string] $Values[$_]).Replace("'", "''")
    }) -join ';')
}

function Write-DBSqlOption {
    param([string] $Path, [Collections.IDictionary] $Values)
    $connection = ConvertTo-DBSqlConnection $Values
    # Quote the response-file argument using the Windows command-line rules.
    $quoted = '"' + [regex]::Replace($connection, '(\\*)"', '$1$1\"') + '"'
    [IO.File]::WriteAllText($Path, "-c $quoted", [Text.UTF8Encoding]::new($false))
}

function Invoke-DBSqlAnywhere {
    param([Collections.IDictionary] $Configuration, $Job, $Runtime)
    $started = [DateTime]::UtcNow
    $connection = Read-DBSqlConnection $Configuration.Database.ConnectionOptionsFile
    if ($connection.DBN -cne $Configuration.Database.Name) { throw 'SQL DBN must match Database.Name.' }
    $secretRoot = Join-Path $Runtime.Work '_secrets'
    Set-DBPrivateDirectory $secretRoot
    $root = Join-Path $Runtime.Work $Job.Id
    $null = New-Item -ItemType Directory -Path $root -Force
    $backupOptions = Join-Path $secretRoot 'backup.options'
    $validationOptions = Join-Path $secretRoot 'validation.options'
    try {
        $connection.ASTART = 'NO'
        Write-DBSqlOption $backupOptions $connection
        # Default dbbackup copies ALL files; do not add -r, -x, -xo, -n, -s.
        $backup = Invoke-DBTool -Executable $Configuration.Tools.DbBackup -Arguments @("@$backupOptions", $root)
        if ($backup.ExitCode -ne 0) { throw "SQL Anywhere backup failed (exit $($backup.ExitCode)); tool output omitted to protect credentials." }
        $dbs = @(Get-ChildItem -LiteralPath $root -File -Filter '*.db')
        $logs = @(Get-ChildItem -LiteralPath $root -File -Filter '*.log')
        if ($dbs.Count -ne 1 -or $logs.Count -lt 1) { throw 'Expected one main .db and at least one transaction .log in the copied backup.' }
        $before = @{}
        foreach ($file in Get-ChildItem -LiteralPath $root -File -Recurse) { $before[$file.FullName] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash }
        $engine = $Configuration.Tools.DbEngine
        if ($engine -match '[";\r\n]') { throw 'Unsafe SQL engine path.' }
        $local = @{
            UID = $connection.UID; PWD = $connection.PWD; DBF = $dbs[0].FullName
            SERVER = "dbbackup_$($Runtime.RunId)"; DBN = 'validation'
            LINKS = 'SHMEM'; ASTART = 'YES'; ASTOP = 'YES'; CPOOL = 'NO'; INT = 'NO'
            START = "`"$engine`" -qi -x none -sb 0 -sf all -im v -ga"
        }
        Write-DBSqlOption $validationOptions $local
        foreach ($flags in @(@('-d'), @())) {
            $argsList = @("@$validationOptions", '-im', 'v') + @($flags)
            $validation = Invoke-DBTool -Executable $Configuration.Tools.DbValid -Arguments $argsList
            if ($validation.ExitCode -ne 0) { throw "SQL Anywhere copied-backup validation failed (exit $($validation.ExitCode))." }
        }
        foreach ($file in $before.Keys) {
            if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -cne $before[$file]) { throw 'Validation modified a copied backup file.' }
        }
        [pscustomobject]@{
            Status = 'SUCCESS'; Packages = @([pscustomobject]@{ Role = 'FULL'; SourcePath = $root; ContentsOnly = $true })
            Errors = @(); StartedAtUtc = $started; FinishedAtUtc = [DateTime]::UtcNow
            Metadata = @{
                Strategy = 'native-full-database-and-log'; Database = $Configuration.Database.Name
                Validation = 'dbvalid-structure-and-tables-in-memory'; Network = 'disabled-for-validation'
                CopiedFilesUnchanged = $true; ProductionLogRename = $false; ProductionLogTruncate = $false
            }
        }
    }
    finally {
        foreach ($file in @($backupOptions, $validationOptions)) { if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force -ErrorAction Stop } }
    }
}
Export-ModuleMember -Function Read-DBSqlConnection, Invoke-DBSqlAnywhere
