Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Configuration.psm1')
Import-Module (Join-Path $PSScriptRoot 'Runtime.psm1')
Import-Module (Join-Path $PSScriptRoot 'Observation.psm1')
Import-Module (Join-Path $PSScriptRoot 'Capacity.psm1')

function Invoke-DBBackup {
    param([string] $ConfigPath, [string] $Job, [switch] $All)
    try {
        $c = Read-DBConfiguration $ConfigPath
        $jobs = if ($All) { @($c.Jobs) } else { @($c.Jobs | Where-Object Id -EQ $Job) }
        if ($jobs.Count -eq 0) { throw "Unknown job: $Job" }
        # Fail before creating state while a required delivery stage is absent.
        $providerDispatcher = Join-Path (Split-Path -Parent $PSScriptRoot) 'Providers/Providers.psm1'
        $artifacts = Join-Path $PSScriptRoot 'Artifacts.psm1'
        if (-not (Test-Path -LiteralPath $providerDispatcher) -or -not (Test-Path -LiteralPath $artifacts)) {
            throw 'This development snapshot does not yet include the complete backup pipeline.'
        }
        Import-Module $providerDispatcher
        Import-Module $artifacts
    }
    catch { Write-Error (Protect-DBMessage $_.Exception.Message) -ErrorAction Continue; return 2 }
    $runtime = $null
    $exitCode = 1
    $ready = $false
    $monitored = [Collections.Generic.HashSet[string]]::new()
    $runWatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $runtime = New-DBRuntime $c
        if ($null -eq $runtime) { return 3 }
        Write-DBLog $runtime.LogPath 'Startup' "DBBackup instance $($c.InstanceName); run $($runtime.RunId)."
        Assert-DBBackupDependency -Configuration $c -Jobs $jobs
        $ready = $true
        $failed = $false
        $degraded = $false
        foreach ($j in $jobs) {
            if (-not (Invoke-DBPendingRetry -Configuration $c -Runtime $runtime -Job $j.Id)) { $failed = $true }
        }
        foreach ($j in $jobs) {
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $jobStatus = 'FAILED'
            try {
                $estimate = if ($j.Provider -eq 'Directory') { Get-DBDirectorySize $j.SourcePath } else { $c.Execution.EstimatedDatabaseBytes }
                Assert-DBFreeSpace -Path $runtime.Work -RequiredBytes $estimate -ReserveBytes $c.Execution.ReserveBytes
                $result = Invoke-DBProvider -Configuration $c -Job $j -Runtime $runtime
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
                Publish-DBJobMonitoring -Configuration $c -Job $j -Status $jobStatus -DurationSeconds $watch.Elapsed.TotalSeconds -LogPath $runtime.LogPath
                $null = $monitored.Add($j.Id)
            }
        }
        $maintenance = $true
        try { Remove-DBExpired -Configuration $c -Runtime $runtime }
        catch { $maintenance = $false; Write-DBLog $runtime.LogPath 'Retention' $_.Exception.Message 'ERROR' }
        Write-DBLog $runtime.LogPath 'Complete' "Failed=$failed; degraded=$degraded; maintenance=$maintenance."
        try { Publish-DBLog -Configuration $c -Runtime $runtime }
        catch { $failed = $true; Write-DBLog $runtime.LogPath 'LogUpload' $_.Exception.Message 'ERROR' }
        if ($failed -or ($degraded -and -not $maintenance)) { $exitCode = 1 }
        elseif (-not $maintenance) { $exitCode = 4 }
        elseif ($degraded) { $exitCode = 5 }
        else { $exitCode = 0 }
    }
    catch {
        if ($null -ne $runtime) { Write-DBLog $runtime.LogPath 'Execution' $_.Exception.Message 'ERROR' }
        else { Write-Error (Protect-DBMessage $_.Exception.Message) -ErrorAction Continue }
        $exitCode = if ($ready) { 1 } else { 2 }
        if ($null -ne $runtime) {
            foreach ($j in $jobs) {
                if (-not $monitored.Contains($j.Id)) { Publish-DBJobMonitoring -Configuration $c -Job $j -Status FAILED -DurationSeconds $runWatch.Elapsed.TotalSeconds -LogPath $runtime.LogPath }
            }
        }
    }
    finally {
        if ($null -ne $runtime) {
            try { Close-DBRuntime $runtime }
            catch {
                Write-DBLog $runtime.LogPath 'Cleanup' $_.Exception.Message 'ERROR'
                $exitCode = if ($exitCode -in @(0,4)) { 4 } else { 1 }
            }
        }
    }
    return $exitCode
}
Export-ModuleMember -Function Invoke-DBBackup
