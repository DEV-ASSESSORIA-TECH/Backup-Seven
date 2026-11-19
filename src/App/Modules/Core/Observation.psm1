Set-StrictMode -Version Latest
foreach ($name in @('Monitoring','Schedule','Runtime')) { Import-Module (Join-Path $PSScriptRoot "$name.psm1") }

function Get-DBApplicationVersion {
    foreach ($relative in @('../../VERSION','../../../../VERSION')) {
        $path = Join-Path $PSScriptRoot $relative
        if (Test-Path -LiteralPath $path -PathType Leaf) { return (Get-Content -LiteralPath $path -Raw).Trim() }
    }
    throw 'VERSION is missing.'
}

function Publish-DBJobMonitoring {
    param([Collections.IDictionary] $Configuration, $Job, [ValidateSet('SUCCESS','FAILED','DEGRADED')][string] $Status,
        [double] $DurationSeconds, [string] $LogPath, [ValidateSet('Full','Incremental')][string] $Mode = 'Full')
    # Returns $false when the producer could not observe the state or could not
    # write the textfile, so the run reports an auxiliary failure (exit 4).
    if (-not $Configuration.Monitoring.Enabled) { return $true }
    $m = $Configuration.Monitoring
    # The incremental of a job is a series of its own: backup_id <id>-log, kind=log.
    # Its last success counts incrementals and fulls (both are recovery points).
    $incremental = $Mode -eq 'Incremental'
    $backupId = if ($incremental) { "$($m.BackupIds[$Job.Id])-log" } else { $m.BackupIds[$Job.Id] }
    $checkpoint = if ($incremental) { "$($Job.Id)-log" } else { $Job.Id }
    $roles = if ($incremental) { @('INCREMENTAL','FULL') } else { @('FULL') }
    $collected = [DateTime]::UtcNow
    $success = [long] 0
    $size = $null
    $due = $null
    $interval = $null
    $collectionOk = $true
    try {
        $stateRoot = Join-Path $Configuration.Paths.RuntimeRoot 'Monitoring'
        $statePath = Join-Path $stateRoot "$checkpoint.json"
        if (Test-Path -LiteralPath $statePath) {
            $previous = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
            if ($previous.SchemaVersion -ne 1 -or $previous.Instance -cne $Configuration.InstanceName -or $previous.Job -cne $Job.Id) { throw 'Monitoring checkpoint ownership mismatch.' }
            $success = [long] $previous.LastSuccessTimestamp
            $size = $previous.LastSuccessSizeBytes
            $due = $previous.SuccessDueTimestamp
        }
        $metricPath = Join-Path $m.TextfileDirectory (Get-DBBackupMetricFileName $m.Service $backupId)
        $previousMetric = Read-DBBackupMetricState $metricPath
        if ($previousMetric.LastSuccessTimestamp -gt $success) { $success = $previousMetric.LastSuccessTimestamp; $size = $previousMetric.LastSuccessSizeBytes; $due = $previousMetric.SuccessDueTimestamp }
        $completed = Join-Path $Configuration.Paths.CompletedRoot $Job.Id
        if (Test-Path -LiteralPath $completed) {
            foreach ($bundle in Get-ChildItem -LiteralPath $completed -Directory) {
                if ($bundle.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Completed monitoring source cannot be a link.' }
                $state = Get-Content -LiteralPath (Join-Path $bundle.FullName 'state.json') -Raw | ConvertFrom-Json
                if ($state.SchemaVersion -ne 1 -or $state.Instance -cne $Configuration.InstanceName -or $state.Job -cne $Job.Id) { throw 'Completed state ownership mismatch.' }
                if ($state.LocalStatus -cne 'SUCCESS' -or $state.Transport -cne 'CONFIRMED' -or $state.Role -cnotin $roles) { continue }
                if ([IO.Path]::GetFileName($state.FileName) -cne $state.FileName) { throw 'Invalid completed file name.' }
                $removedProperty = $state.PSObject.Properties['LocalPayload']
                if ($null -eq $removedProperty -or $removedProperty.Value -cne 'REMOVED') {
                    $payload = Get-Item -LiteralPath (Join-Path $bundle.FullName $state.FileName)
                    if ($payload.Length -ne $state.SizeBytes -or $payload.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Completed size or path mismatch.' }
                }
                $timestamp = ([DateTimeOffset] ([datetime] $state.RecoveryPointUtc).ToUniversalTime()).ToUnixTimeSeconds()
                if ($timestamp -gt $success) { $success = $timestamp; $size = [long] $state.SizeBytes; $due = $null }
            }
        }
        if (-not $incremental -and $m.ExpectedIntervalHours.Contains($Job.Id)) { $interval = [double] $m.ExpectedIntervalHours[$Job.Id] * 3600 }
        if ($Configuration.Contains('Schedule')) {
            try {
                $tasks = @(Get-DBScheduleTask $Configuration)
                if ($null -eq $interval) { $gap = Get-DBScheduleMaxGap -Tasks $tasks -Job $Job.Id -Mode $Mode; if ($null -ne $gap) { $interval = $gap * 3600 } }
                if ($success -gt 0 -or $null -eq $due) {
                    $after = if ($success -gt 0) { [DateTimeOffset]::FromUnixTimeSeconds($success).LocalDateTime } else { [datetime]::Now }
                    $next = Get-DBScheduleNextRun -Tasks $tasks -Job $Job.Id -After $after -Mode $Mode
                    $due = if ($null -ne $next) { ([DateTimeOffset] $next).ToUnixTimeSeconds() } else { $null }
                }
            }
            catch { $due = $null; Write-DBLog $LogPath 'Monitoring/Schedule' $_.Exception.Message 'WARN' }
        }
        else { $due = $null }
        Set-DBPrivateDirectory $stateRoot
        $temp = "$statePath.tmp"
        try {
            @{SchemaVersion=1;Instance=$Configuration.InstanceName;Job=$Job.Id;LastSuccessTimestamp=$success;LastSuccessSizeBytes=$size;SuccessDueTimestamp=$due} |
                ConvertTo-Json | Set-Content -LiteralPath $temp -Encoding utf8
            [IO.File]::Move($temp,$statePath,$true)
        }
        finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
    }
    catch { $collectionOk = $false; Write-DBLog $LogPath 'Monitoring/Collection' $_.Exception.Message 'WARN' }
    try {
        $content = Format-DBBackupMetric -Service $m.Service -BackupId $backupId -CollectedAtUtc $collected -CollectionSucceeded $collectionOk `
            -AttemptFinishedAtUtc $collected -AttemptSucceeded ($Status -eq 'SUCCESS') -AttemptDegraded ($Status -eq 'DEGRADED') `
            -AttemptDurationSeconds $DurationSeconds -LastSuccessTimestamp $success -LastSuccessSizeBytes $size -ExpectedIntervalSeconds $interval -SuccessDueTimestamp $due `
            -InfoLabels @{kind=$(if($incremental){'log'}elseif($Job.Provider -eq 'Directory'){'files'}else{'database'});producer='dbbackup';producer_version=(Get-DBApplicationVersion);site=$Configuration.InstanceName.ToLowerInvariant();criticality=$m.Criticality[$Job.Id];destination=$Configuration.Storage.Destination}
        $null = Write-DBBackupMetric -Directory $m.TextfileDirectory -Service $m.Service -BackupId $backupId -Content $content
    }
    catch { Write-DBLog $LogPath 'Monitoring/Write' $_.Exception.Message 'WARN'; return $false }
    return $collectionOk
}
Export-ModuleMember -Function Publish-DBJobMonitoring, Get-DBApplicationVersion
