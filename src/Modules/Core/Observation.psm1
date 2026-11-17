Set-StrictMode -Version Latest
foreach ($name in @('Monitoring','Schedule','Runtime')) { Import-Module (Join-Path $PSScriptRoot "$name.psm1") }

function Get-DBApplicationVersion {
    foreach ($relative in @('../../VERSION','../../../VERSION')) {
        $path = Join-Path $PSScriptRoot $relative
        if (Test-Path -LiteralPath $path -PathType Leaf) { return (Get-Content -LiteralPath $path -Raw).Trim() }
    }
    throw 'VERSION is missing.'
}

function Publish-DBJobMonitoring {
    param([Collections.IDictionary] $Configuration, $Job, [ValidateSet('SUCCESS','FAILED','DEGRADED')][string] $Status,
        [double] $DurationSeconds, [string] $LogPath)
    if (-not $Configuration.Monitoring.Enabled) { return }
    $m = $Configuration.Monitoring
    $collected = [DateTime]::UtcNow
    $success = [long] 0
    $size = $null
    $due = $null
    $interval = $null
    $collectionOk = $true
    try {
        $stateRoot = Join-Path $Configuration.Paths.RuntimeRoot 'Monitoring'
        $statePath = Join-Path $stateRoot "$($Job.Id).json"
        if (Test-Path -LiteralPath $statePath) {
            $previous = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
            if ($previous.SchemaVersion -ne 1 -or $previous.Instance -cne $Configuration.InstanceName -or $previous.Job -cne $Job.Id) { throw 'Monitoring checkpoint ownership mismatch.' }
            $success = [long] $previous.LastSuccessTimestamp
            $size = $previous.LastSuccessSizeBytes
            $due = $previous.SuccessDueTimestamp
        }
        $metricPath = Join-Path $m.TextfileDirectory (Get-DBBackupMetricFileName $m.Service $m.BackupIds[$Job.Id])
        $previousMetric = Read-DBBackupMetricState $metricPath
        if ($previousMetric.LastSuccessTimestamp -gt $success) { $success = $previousMetric.LastSuccessTimestamp; $size = $previousMetric.LastSuccessSizeBytes; $due = $previousMetric.SuccessDueTimestamp }
        $completed = Join-Path $Configuration.Paths.CompletedRoot $Job.Id
        if (Test-Path -LiteralPath $completed) {
            foreach ($bundle in Get-ChildItem -LiteralPath $completed -Directory) {
                if ($bundle.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Completed monitoring source cannot be a link.' }
                $state = Get-Content -LiteralPath (Join-Path $bundle.FullName 'state.json') -Raw | ConvertFrom-Json
                if ($state.SchemaVersion -ne 1 -or $state.Instance -cne $Configuration.InstanceName -or $state.Job -cne $Job.Id) { throw 'Completed state ownership mismatch.' }
                if ($state.LocalStatus -cne 'SUCCESS' -or $state.Transport -cne 'CONFIRMED' -or $state.Role -cne 'FULL') { continue }
                if ([IO.Path]::GetFileName($state.FileName) -cne $state.FileName) { throw 'Invalid completed file name.' }
                $payload = Get-Item -LiteralPath (Join-Path $bundle.FullName $state.FileName)
                if ($payload.Length -ne $state.SizeBytes -or $payload.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Completed size or path mismatch.' }
                $timestamp = ([DateTimeOffset] ([datetime] $state.RecoveryPointUtc).ToUniversalTime()).ToUnixTimeSeconds()
                if ($timestamp -gt $success) { $success = $timestamp; $size = [long] $state.SizeBytes; $due = $null }
            }
        }
        if ($m.ExpectedIntervalHours.Contains($Job.Id)) { $interval = [double] $m.ExpectedIntervalHours[$Job.Id] * 3600 }
        if ($Configuration.Contains('Schedule')) {
            try {
                $tasks = @(Get-DBScheduleTask $Configuration)
                if ($null -eq $interval) { $gap = Get-DBScheduleMaxGap -Tasks $tasks -Job $Job.Id; if ($null -ne $gap) { $interval = $gap * 3600 } }
                if ($success -gt 0 -or $null -eq $due) {
                    $after = if ($success -gt 0) { [DateTimeOffset]::FromUnixTimeSeconds($success).LocalDateTime } else { [datetime]::Now }
                    $next = Get-DBScheduleNextRun -Tasks $tasks -Job $Job.Id -After $after
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
        $content = Format-DBBackupMetric -Service $m.Service -BackupId $m.BackupIds[$Job.Id] -CollectedAtUtc $collected -CollectionSucceeded $collectionOk `
            -AttemptFinishedAtUtc $collected -AttemptSucceeded ($Status -eq 'SUCCESS') -AttemptDegraded ($Status -eq 'DEGRADED') `
            -AttemptDurationSeconds $DurationSeconds -LastSuccessTimestamp $success -LastSuccessSizeBytes $size -ExpectedIntervalSeconds $interval -SuccessDueTimestamp $due `
            -InfoLabels @{kind=$(if($Job.Provider -eq 'Directory'){'files'}else{'database'});producer='dbbackup';producer_version=(Get-DBApplicationVersion);site=$Configuration.InstanceName.ToLowerInvariant();criticality=$m.Criticality[$Job.Id];destination='s3'}
        $null = Write-DBBackupMetric -Directory $m.TextfileDirectory -Service $m.Service -BackupId $m.BackupIds[$Job.Id] -Content $content
    }
    catch { Write-DBLog $LogPath 'Monitoring/Write' $_.Exception.Message 'WARN' }
}
Export-ModuleMember -Function Publish-DBJobMonitoring, Get-DBApplicationVersion
