Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Runtime.psm1')

<#
Cumulative incremental of SQL Anywhere (2.2). The full of an incremental job
renames and restarts the production log (dbbackup -r) and becomes the base;
each incremental copies the current log (dbbackup -t), i.e. everything since
the base. Restore = base full + latest incremental of that base.
The base is kept in <Runtime>\Incremental\<job>.json.
#>

function Get-DBIncrementalBasePath {
    param([Collections.IDictionary] $Configuration, [string] $Job)
    return Join-Path (Join-Path $Configuration.Paths.RuntimeRoot 'Incremental') "$Job.json"
}

function Read-DBIncrementalBase {
    <# The recorded base full of a job, or $null when there is none. #>
    param([Collections.IDictionary] $Configuration, [string] $Job)
    $path = Get-DBIncrementalBasePath $Configuration $Job
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $base = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($base.SchemaVersion -ne 1 -or $base.Instance -cne $Configuration.InstanceName -or $base.Job -cne $Job) { throw 'Incremental base ownership mismatch.' }
    # ConvertFrom-Json may already return a DateTime: keep a round-trip UTC string.
    $time = if ($base.BaseRecoveryPointUtc -is [DateTime]) { $base.BaseRecoveryPointUtc } else { [DateTime]::Parse([string] $base.BaseRecoveryPointUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
    $base.BaseRecoveryPointUtc = $time.ToUniversalTime().ToString('o')
    return $base
}

function Save-DBIncrementalBase {
    param([Collections.IDictionary] $Configuration, [string] $Job, [string] $RunId, [DateTime] $RecoveryPointUtc, [AllowNull()][string] $LogDirectory)
    $path = Get-DBIncrementalBasePath $Configuration $Job
    Set-DBPrivateDirectory (Split-Path -Parent $path)
    $temp = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        @{
            SchemaVersion = 1; Instance = $Configuration.InstanceName; Job = $Job; BaseRunId = $RunId
            BaseRecoveryPointUtc = $RecoveryPointUtc.ToUniversalTime().ToString('o'); ProductionLogDirectory = $LogDirectory
        } | ConvertTo-Json | Set-Content -LiteralPath $temp -Encoding utf8 -ErrorAction Stop
        [IO.File]::Move($temp, $path, $true)
    }
    finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}

function Clear-DBIncrementalBase {
    <# Without a base the next incremental is promoted to a full. #>
    param([Collections.IDictionary] $Configuration, [string] $Job)
    $path = Get-DBIncrementalBasePath $Configuration $Job
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
}

function Test-DBBaseConfirmed {
    <# True when the base full of the job was uploaded (Completed, CONFIRMED). #>
    param([Collections.IDictionary] $Configuration, [string] $Job, $Base)
    $parent = Join-Path $Configuration.Paths.CompletedRoot $Job
    if (-not (Test-Path -LiteralPath $parent)) { return $false }
    foreach ($bundle in @(Get-ChildItem -LiteralPath $parent -Directory)) {
        $statePath = Join-Path $bundle.FullName 'state.json'
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { continue }
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ($state.Instance -ceq $Configuration.InstanceName -and $state.Job -ceq $Job -and $state.RunId -ceq $Base.BaseRunId -and
            $state.Role -ceq 'FULL' -and $state.Transport -ceq 'CONFIRMED') { return $true }
    }
    return $false
}

function Remove-DBRenamedLog {
    <#
    Deletes the logs renamed by dbbackup -r (AAMMDDxx.log) in the production
    log folder, only when the base full is confirmed in S3 and the file is
    older than both the base and Incremental.KeepRenamedLogDays. The current
    log (e.g. contabil.log) never matches the pattern. Returns the removed names.
    #>
    param([Collections.IDictionary] $Configuration, $Job)
    $base = Read-DBIncrementalBase $Configuration $Job.Id
    if ($null -eq $base) { return @() }
    $directory = [string] $base.ProductionLogDirectory
    if (-not $directory -or -not (Test-Path -LiteralPath $directory -PathType Container)) { return @() }
    if (-not (Test-DBBaseConfirmed $Configuration $Job.Id $base)) { return @() }
    $baseTime = [DateTime]::Parse($base.BaseRecoveryPointUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    $limit = [DateTime]::UtcNow.AddDays(-[int] $Job.KeepRenamedLogDays)
    $removed = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $directory -File -Filter '*.log')) {
        if ($file.Name -notmatch '^\d{6}[0-9A-Za-z]{2}\.log$') { continue }
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if ($file.LastWriteTimeUtc -ge $baseTime -or $file.LastWriteTimeUtc -ge $limit) { continue }
        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
        $removed += $file.Name
    }
    return $removed
}

Export-ModuleMember -Function Get-DBIncrementalBasePath, Read-DBIncrementalBase, Save-DBIncrementalBase, Clear-DBIncrementalBase, Test-DBBaseConfirmed, Remove-DBRenamedLog
