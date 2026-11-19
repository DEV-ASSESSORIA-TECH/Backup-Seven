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
        if ($key.ToUpperInvariant() -notin @('UID','PWD','HOST','DBN','SERVER','ENG','CHARSET')) { throw "Unsupported SQL connection parameter: $key" }
        $value = [string] $builder[$key]
        if ($value -match '["\r\n]') { throw 'SQL connection values cannot contain double quotes or newlines.' }
        $values[$key.ToUpperInvariant()] = $value
    }
    foreach ($key in @('UID','PWD','DBN')) {
        if (-not $values.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($values[$key])) { throw "SQL connection parameter is required: $key" }
    }
    # HOST for TCP/IP; SERVER (or its alias ENG) alone for a local server
    # reached through shared memory.
    if (-not @('HOST','SERVER','ENG' | Where-Object { $values.ContainsKey($_) -and -not [string]::IsNullOrWhiteSpace($values[$_]) }).Count) {
        throw 'SQL connection requires HOST or SERVER (ENG).'
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

function ConvertTo-DBSafeToolOutput {
    <# Native output for diagnostics: the password is removed literally and by pattern, then truncated. #>
    param([AllowNull()][string] $Text, [AllowNull()][string] $Secret, [int] $MaxLength = 2000)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    if (-not [string]::IsNullOrEmpty($Secret)) { $Text = $Text.Replace($Secret, '[REDACTED]') }
    $Text = (Protect-DBMessage $Text).Trim()
    if ($Text.Length -gt $MaxLength) { $Text = $Text.Substring(0, $MaxLength) + '...' }
    return $Text
}

function Get-DBSqlAnywhereSizeEstimate {
    <#
    Best-effort size of the database file (FileSize pages x PageSize) read with
    dbping -d -pd FileSize,PageSize. Used only on the first run of a job, before
    the capacity history exists. Returns $null when dbping is absent, fails or
    its output is not understood; the run then checks only ReserveBytes.
    #>
    param([Collections.IDictionary] $Configuration, $Job, $Runtime)
    if ($null -eq $Runtime) { return $null }
    $dbping = Join-Path (Split-Path -Parent $Configuration.Tools.DbBackup) 'dbping.exe'
    if (-not (Test-Path -LiteralPath $dbping -PathType Leaf)) { return $null }
    $connection = Read-DBSqlConnection $Job.CredentialFile
    # Never start a database just to measure it.
    $connection.ASTART = 'NO'
    # Transient credentials live in the private Work directory of this run.
    $options = Join-Path $Runtime.Work "dbping-$([guid]::NewGuid().ToString('N')).options"
    try {
        Write-DBSqlOption $options $connection
        $probe = Invoke-DBTool -Executable $dbping -Arguments @('-d', '-pd', 'FileSize,PageSize', "@$options") -TimeoutSeconds 60
        if ($probe.ExitCode -ne 0) { return $null }
        $text = "$($probe.StdOut)`n$($probe.StdErr)"
        $pages = [regex]::Match($text, '(?im)\bFileSize\b[^\d\r\n]*(\d+)')
        $pageSize = [regex]::Match($text, '(?im)\bPageSize\b[^\d\r\n]*(\d+)')
        if (-not $pages.Success -or -not $pageSize.Success) { return $null }
        return [long] $pages.Groups[1].Value * [long] $pageSize.Groups[1].Value
    }
    finally { if (Test-Path -LiteralPath $options) { Remove-Item -LiteralPath $options -Force } }
}

function Invoke-DBSqlAnywhere {
    param([Collections.IDictionary] $Configuration, $Job, $Runtime)
    $started = [DateTime]::UtcNow
    $connection = Read-DBSqlConnection $Job.CredentialFile
    if ($connection.DBN -cne $Job.Database) { throw "Job $($Job.Id): SQL DBN must match the job Database." }
    $secretRoot = Join-Path $Runtime.Work '_secrets'
    Set-DBPrivateDirectory $secretRoot
    $root = Join-Path $Runtime.Work $Job.Id
    $null = New-Item -ItemType Directory -Path $root -Force
    $backupOptions = Join-Path $secretRoot 'backup.options'
    try {
        $connection.ASTART = 'NO'
        Write-DBSqlOption $backupOptions $connection
        # Default dbbackup copies ALL files; do not add -r, -x, -xo, -n, -s.
        $timeout = if ($Configuration.Contains('Execution')) { $Configuration.Execution.ToolTimeoutSeconds } else { 21600 }
        $backup = Invoke-DBTool -Executable $Configuration.Tools.DbBackup -Arguments @("@$backupOptions", $root) -TimeoutSeconds $timeout
        if ($backup.ExitCode -ne 0) {
            $detail = ConvertTo-DBSafeToolOutput -Text ("$($backup.StdOut) $($backup.StdErr)") -Secret $connection.PWD
            throw "SQL Anywhere backup failed (exit $($backup.ExitCode)). $detail".Trim()
        }
        # The main database plus any dbspaces are .db files; at least one log.
        $dbs = @(Get-ChildItem -LiteralPath $root -File -Filter '*.db')
        $logs = @(Get-ChildItem -LiteralPath $root -File -Filter '*.log')
        if ($dbs.Count -lt 1 -or $logs.Count -lt 1) { throw 'Expected at least one .db and one transaction .log in the copied backup.' }
        foreach ($file in @($dbs) + @($logs)) {
            if ($file.Length -eq 0) { throw 'SQL Anywhere produced an empty database or log file.' }
        }
        [pscustomobject]@{
            Status = 'SUCCESS'; Packages = @([pscustomobject]@{ Role = 'FULL'; SourcePath = $root; ContentsOnly = $true })
            Errors = @(); StartedAtUtc = $started; FinishedAtUtc = [DateTime]::UtcNow
            Metadata = @{
                Strategy = 'native-full-database-and-log'; Database = $Job.Database
                Validation = 'native-exit-code-and-nonempty-files'; RecoveryValidation = 'external-not-performed'
                ProductionLogRename = $false; ProductionLogTruncate = $false
                DatabaseFiles = @($dbs.Name); LogFiles = @($logs.Name)
            }
        }
    }
    finally {
        # Removes the credential file and its private directory; a run killed
        # before this point is cleaned by the next run (Clear-DBStaleRuntime).
        if (Test-Path -LiteralPath $secretRoot) { Remove-Item -LiteralPath $secretRoot -Recurse -Force -ErrorAction Stop }
    }
}
Export-ModuleMember -Function Read-DBSqlConnection, Write-DBSqlOption, ConvertTo-DBSafeToolOutput, Get-DBSqlAnywhereSizeEstimate, Invoke-DBSqlAnywhere
