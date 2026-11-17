Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Configuration.psm1')
Import-Module (Join-Path $PSScriptRoot 'Runtime.psm1')
Import-Module (Join-Path $PSScriptRoot 'Observation.psm1')
Import-Module (Join-Path $PSScriptRoot 'Capacity.psm1')
Import-Module (Join-Path $PSScriptRoot 'Process.psm1')

function Invoke-DBBackup {
    <#
    Exit codes (precedence 1 > 5 > 4 > 0): 1 a job or pending upload failed;
    5 every job published, at least one degraded; 4 backups published but an
    auxiliary step failed (retention, interrupted-run cleanup, log upload or
    monitoring textfile); 0 success. 2 configuration/dependency; 3 lock busy.
    #>
    param([string] $ConfigPath, [string] $Job, [switch] $All)
    try {
        $c = Read-DBConfiguration $ConfigPath
        $jobs = if ($All) { @($c.Jobs) } else { @($c.Jobs | Where-Object Id -EQ $Job) }
        if ($jobs.Count -eq 0) { throw "Unknown job: $Job" }
        Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Providers/Providers.psm1')
        Import-Module (Join-Path $PSScriptRoot 'Artifacts.psm1')
    }
    catch { Write-Error (Protect-DBMessage $_.Exception.Message) -ErrorAction Continue; return 2 }
    $runtime = $null
    $exitCode = 1
    $ready = $false
    $monitored = [Collections.Generic.HashSet[string]]::new()
    $runWatch = [Diagnostics.Stopwatch]::StartNew()
    $maintenance = $true
    try {
        $runtime = New-DBRuntime $c
        if ($null -eq $runtime) { return 3 }
        Write-DBLog $runtime.LogPath 'Startup' "DBBackup instance $($c.InstanceName); run $($runtime.RunId)."
        # The deadline covers every native tool of the run, retries included.
        $deadline = [DateTime]::UtcNow.AddSeconds([double] $c.Execution.RunTimeoutSeconds)
        Set-DBToolDeadline $deadline
        Write-DBLog $runtime.LogPath 'Startup' "Run deadline $($deadline.ToString('o')) (Execution.RunTimeoutSeconds=$($c.Execution.RunTimeoutSeconds))."
        try {
            $stale = Clear-DBStaleRuntime $runtime
            foreach ($path in $stale.Removed) { Write-DBLog $runtime.LogPath 'Cleanup' "Removed content left by an interrupted run: $path" 'WARN' }
            foreach ($path in $stale.Skipped) { Write-DBLog $runtime.LogPath 'Cleanup' "Unexpected item left untouched in Work/Staging: $path" 'WARN'; $maintenance = $false }
        }
        catch { $maintenance = $false; Write-DBLog $runtime.LogPath 'Cleanup' "Interrupted-run cleanup failed: $($_.Exception.Message)" 'ERROR' }
        Assert-DBBackupDependency -Configuration $c -Jobs $jobs
        $ready = $true
        $failed = $false
        $degraded = $false
        foreach ($j in $jobs) {
            if (-not (Invoke-DBPendingRetry -Configuration $c -Runtime $runtime -Job $j.Id)) { $failed = $true }
            $pending = Get-DBPendingSummary -Runtime $runtime -Job $j.Id
            if ($pending.Count -gt 0) {
                Write-DBLog $runtime.LogPath $j.Id "$($pending.Count) encrypted bundle(s) still awaiting upload in Pending ($($pending.Bytes) bytes)." 'WARN'
            }
        }
        foreach ($j in $jobs) {
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $jobStatus = 'FAILED'
            try {
                Assert-DBToolDeadline
                $estimate = Get-DBJobSpaceEstimate -Configuration $c -Job $j
                if ($estimate.Source -eq 'unknown') {
                    try {
                        $probed = Get-DBProviderSizeEstimate -Configuration $c -Job $j
                        if ($null -ne $probed -and [long] $probed -gt 0) {
                            $estimate = [pscustomobject]@{ Bytes = [long] ([decimal] $probed * 1.25); Source = 'provider-probe+25%'; Warning = $estimate.Warning }
                        }
                    }
                    catch { $estimate.Warning = (@($estimate.Warning, "Provider size probe failed: $(Protect-DBMessage $_.Exception.Message)") | Where-Object { $_ }) -join ' ' }
                }
                if ($estimate.Warning) { Write-DBLog $runtime.LogPath $j.Id $estimate.Warning 'WARN' }
                if ($estimate.Source -eq 'unknown') { Write-DBLog $runtime.LogPath $j.Id 'No space estimate is available; only ReserveBytes is checked. Set Execution.EstimatedDatabaseBytes.' 'WARN' }
                Write-DBLog $runtime.LogPath $j.Id "Space estimate: $($estimate.Bytes) bytes ($($estimate.Source))."
                Assert-DBFreeSpace -Path $runtime.Work -RequiredBytes $estimate.Bytes -ReserveBytes $c.Execution.ReserveBytes
                $result = Invoke-DBProvider -Configuration $c -Job $j -Runtime $runtime
                if ($result.Status -eq 'SUCCESS' -and $j.Provider -ne 'Directory') {
                    try {
                        [long] $payloadBytes = 0
                        foreach ($package in $result.Packages) { $payloadBytes += Get-DBDirectorySize $package.SourcePath }
                        Save-DBCapacityHistory -Configuration $c -Job $j.Id -PayloadBytes $payloadBytes
                    }
                    catch { Write-DBLog $runtime.LogPath $j.Id "Capacity history not updated: $($_.Exception.Message)" 'WARN' }
                }
                $published = 0
                foreach ($package in $result.Packages) {
                    try {
                        Publish-DBPackage -Configuration $c -Runtime $runtime -Job $j -Result $result -Package $package
                        $published++
                    }
                    catch { $failed = $true; Write-DBLog $runtime.LogPath $j.Id $_.Exception.Message 'ERROR' }
                }
                if ($result.Status -eq 'FAILED' -or $published -ne $result.Packages.Count -or $published -eq 0) { $failed = $true }
                if ($published -eq $result.Packages.Count -and $published -gt 0 -and $result.Status -ne 'FAILED') { $jobStatus = $result.Status }
                if ($result.Status -eq 'DEGRADED') { $degraded = $true }
                foreach ($errorMessage in $result.Errors) { Write-DBLog $runtime.LogPath $j.Id $errorMessage 'WARN' }
                Write-DBLog $runtime.LogPath $j.Id "Local result: $($result.Status); published packages: $published."
            }
            catch { $failed = $true; Write-DBLog $runtime.LogPath $j.Id $_.Exception.Message 'ERROR' }
            finally {
                if (-not (Publish-DBJobMonitoring -Configuration $c -Job $j -Status $jobStatus -DurationSeconds $watch.Elapsed.TotalSeconds -LogPath $runtime.LogPath)) { $maintenance = $false }
                $null = $monitored.Add($j.Id)
            }
        }
        try { Remove-DBExpired -Configuration $c -Runtime $runtime }
        catch { $maintenance = $false; Write-DBLog $runtime.LogPath 'Retention' $_.Exception.Message 'ERROR' }
        # The log upload is auxiliary: it gets its own short limit outside the
        # run deadline and never turns published backups into a failure.
        Set-DBToolDeadline $null
        Write-DBLog $runtime.LogPath 'Complete' "Failed=$failed; degraded=$degraded; maintenance=$maintenance."
        try { Publish-DBLog -Configuration $c -Runtime $runtime -TimeoutSeconds ([Math]::Min(900, [double] $c.Execution.ToolTimeoutSeconds)) }
        catch { $maintenance = $false; Write-DBLog $runtime.LogPath 'LogUpload' $_.Exception.Message 'ERROR' }
        if ($failed) { $exitCode = 1 }
        elseif ($degraded) { $exitCode = 5 }
        elseif (-not $maintenance) { $exitCode = 4 }
        else { $exitCode = 0 }
        if (-not $maintenance) { Write-DBLog $runtime.LogPath 'Complete' "Auxiliary step failed; exit code $exitCode." 'WARN' }
    }
    catch {
        if ($null -ne $runtime) { Write-DBLog $runtime.LogPath 'Execution' $_.Exception.Message 'ERROR' }
        else { Write-Error (Protect-DBMessage $_.Exception.Message) -ErrorAction Continue }
        $exitCode = if ($ready) { 1 } else { 2 }
        if ($null -ne $runtime) {
            foreach ($j in $jobs) {
                if (-not $monitored.Contains($j.Id)) { $null = Publish-DBJobMonitoring -Configuration $c -Job $j -Status FAILED -DurationSeconds $runWatch.Elapsed.TotalSeconds -LogPath $runtime.LogPath }
            }
        }
    }
    finally {
        Set-DBToolDeadline $null
        if ($null -ne $runtime) {
            try { Close-DBRuntime $runtime }
            catch {
                Write-DBLog $runtime.LogPath 'Cleanup' $_.Exception.Message 'ERROR'
                $exitCode = if ($exitCode -in @(0,4)) { 4 } else { $exitCode }
            }
        }
    }
    return $exitCode
}
Export-ModuleMember -Function Invoke-DBBackup
