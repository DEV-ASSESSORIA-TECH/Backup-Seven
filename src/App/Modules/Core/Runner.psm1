Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Configuration.psm1')
Import-Module (Join-Path $PSScriptRoot 'Runtime.psm1')
Import-Module (Join-Path $PSScriptRoot 'Observation.psm1')
Import-Module (Join-Path $PSScriptRoot 'Capacity.psm1')
Import-Module (Join-Path $PSScriptRoot 'Process.psm1')

function Get-DBRunExitCode {
    param([bool] $Failed, [bool] $Degraded, [bool] $Maintenance)
    if ($Failed) { return 1 }
    if ($Degraded) { return 5 }
    if (-not $Maintenance) { return 4 }
    return 0
}

function Write-DBRunResult {
    <#
    Last line of every run log, readable without knowing exit codes, e.g.
    "RESULTADO: FALHA (exit 1) - jobs com falha: seven". The last RESULTADO
    line in the file is the final one.
    #>
    param([string] $LogPath, [int] $ExitCode, [string[]] $FailedJobs = @(), [string[]] $DegradedJobs = @(), [string[]] $Auxiliary = @(), [string] $Reason)
    $label = switch ($ExitCode) { 0 { 'SUCESSO' } 1 { 'FALHA' } 2 { 'ERRO DE CONFIGURACAO' } 4 { 'ATENCAO' } 5 { 'DEGRADADO' } default { 'FALHA' } }
    $details = @()
    if ($FailedJobs.Count) { $details += "jobs com falha: $(@($FailedJobs | Select-Object -Unique) -join ', ')" }
    if ($DegradedJobs.Count) { $details += "jobs degradados: $(@($DegradedJobs | Select-Object -Unique) -join ', ')" }
    if ($Auxiliary.Count) { $details += "etapas auxiliares com falha: $(@($Auxiliary | Select-Object -Unique) -join ', ')" }
    if ($Reason) { $details += $Reason }
    $text = "RESULTADO: $label (exit $ExitCode)"
    if ($details.Count) { $text += ' - ' + ($details -join '; ') }
    $level = if ($ExitCode -eq 0) { 'INFO' } elseif ($ExitCode -in @(4,5)) { 'WARN' } else { 'ERROR' }
    Write-DBLog $LogPath 'Result' $text $level
}

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
        if ($All) { $jobs = @($c.Jobs) }
        else {
            # -Job accepts one ID or a comma-separated list, in the given order.
            $requested = @($Job -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if ($requested.Count -eq 0) { throw 'No job was requested.' }
            $jobs = @(foreach ($id in $requested) {
                $match = @($c.Jobs | Where-Object { $_.Id -ceq $id })
                if ($match.Count -ne 1) { throw "Unknown job: $id (configured: $(@($c.Jobs.Id) -join ', '))" }
                $match[0]
            })
        }
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
    $failedJobs = [Collections.Generic.List[string]]::new()
    $degradedJobs = [Collections.Generic.List[string]]::new()
    $auxiliary = [Collections.Generic.List[string]]::new()
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
            foreach ($path in $stale.Skipped) { Write-DBLog $runtime.LogPath 'Cleanup' "Unexpected item left untouched in Work/Staging: $path" 'WARN'; $maintenance = $false; $auxiliary.Add('limpeza de execucao interrompida') }
        }
        catch { $maintenance = $false; $auxiliary.Add('limpeza de execucao interrompida'); Write-DBLog $runtime.LogPath 'Cleanup' "Interrupted-run cleanup failed: $($_.Exception.Message)" 'ERROR' }
        Assert-DBBackupDependency -Configuration $c -Jobs $jobs
        $ready = $true
        $failed = $false
        $degraded = $false
        foreach ($j in $jobs) {
            if (-not (Invoke-DBPendingRetry -Configuration $c -Runtime $runtime -Job $j.Id)) { $failed = $true; $failedJobs.Add("$($j.Id) (reenvio de pendencia)") }
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
                        $probed = Get-DBProviderSizeEstimate -Configuration $c -Job $j -Runtime $runtime
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
                $source = if ($j.Provider -eq 'Directory') { $j.SourcePath } else { "database $($j.Database)" }
                Write-DBLog $runtime.LogPath $j.Id "Step 1/4: $($j.Provider) backup of $source started."
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
                if ($result.Status -eq 'FAILED' -or $published -ne $result.Packages.Count -or $published -eq 0) { $failed = $true; $failedJobs.Add($j.Id) }
                if ($published -eq $result.Packages.Count -and $published -gt 0 -and $result.Status -ne 'FAILED') { $jobStatus = $result.Status }
                if ($result.Status -eq 'DEGRADED') { $degraded = $true; $degradedJobs.Add($j.Id) }
                foreach ($errorMessage in $result.Errors) { Write-DBLog $runtime.LogPath $j.Id $errorMessage 'WARN' }
                Write-DBLog $runtime.LogPath $j.Id "Local result: $($result.Status); published packages: $published."
            }
            catch { $failed = $true; $failedJobs.Add($j.Id); Write-DBLog $runtime.LogPath $j.Id $_.Exception.Message 'ERROR' }
            finally {
                if (-not (Publish-DBJobMonitoring -Configuration $c -Job $j -Status $jobStatus -DurationSeconds $watch.Elapsed.TotalSeconds -LogPath $runtime.LogPath)) { $maintenance = $false; $auxiliary.Add("monitoramento ($($j.Id))") }
                $null = $monitored.Add($j.Id)
            }
        }
        try { Remove-DBExpired -Configuration $c -Runtime $runtime }
        catch { $maintenance = $false; $auxiliary.Add('retencao local'); Write-DBLog $runtime.LogPath 'Retention' $_.Exception.Message 'ERROR' }
        # The log upload is auxiliary: it gets its own short limit outside the
        # run deadline and never turns published backups into a failure.
        Set-DBToolDeadline $null
        Write-DBLog $runtime.LogPath 'Complete' "Failed=$failed; degraded=$degraded; maintenance=$maintenance."
        $exitCode = Get-DBRunExitCode -Failed $failed -Degraded $degraded -Maintenance $maintenance
        # The uploaded copy ends with the result known before its own upload.
        Write-DBRunResult $runtime.LogPath $exitCode $failedJobs $degradedJobs $auxiliary
        try { Publish-DBLog -Configuration $c -Runtime $runtime -Jobs $jobs -TimeoutSeconds ([Math]::Min(900, [double] $c.Execution.ToolTimeoutSeconds)) }
        catch {
            $maintenance = $false
            $auxiliary.Add('envio do log')
            Write-DBLog $runtime.LogPath 'LogUpload' $_.Exception.Message 'ERROR'
            $exitCode = Get-DBRunExitCode -Failed $failed -Degraded $degraded -Maintenance $maintenance
            Write-DBRunResult $runtime.LogPath $exitCode $failedJobs $degradedJobs $auxiliary
        }
    }
    catch {
        if ($null -ne $runtime) { Write-DBLog $runtime.LogPath 'Execution' $_.Exception.Message 'ERROR' }
        else { Write-Error (Protect-DBMessage $_.Exception.Message) -ErrorAction Continue }
        $exitCode = if ($ready) { 1 } else { 2 }
        if ($null -ne $runtime) { Write-DBRunResult $runtime.LogPath $exitCode $failedJobs $degradedJobs $auxiliary -Reason (Protect-DBMessage $_.Exception.Message) }
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
                $auxiliary.Add('limpeza do Work')
                Write-DBRunResult $runtime.LogPath $exitCode $failedJobs $degradedJobs $auxiliary
            }
        }
    }
    return $exitCode
}
Export-ModuleMember -Function Invoke-DBBackup
