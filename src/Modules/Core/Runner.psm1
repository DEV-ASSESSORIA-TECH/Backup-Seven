Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Configuration.psm1')
Import-Module (Join-Path $PSScriptRoot 'Runtime.psm1')

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
        Assert-DBBackupDependency -Configuration $c -Jobs $jobs
    }
    catch { Write-Error (Protect-DBMessage $_.Exception.Message) -ErrorAction Continue; return 2 }
    $runtime = $null
    try {
        $runtime = New-DBRuntime $c
        if ($null -eq $runtime) { return 3 }
        Write-DBLog $runtime.LogPath 'Startup' "DBBackup instance $($c.InstanceName); run $($runtime.RunId)."
        $failed = $false
        $degraded = $false
        foreach ($j in $jobs) {
            if (-not (Invoke-DBPendingRetry -Configuration $c -Runtime $runtime -Job $j.Id)) { $failed = $true }
        }
        foreach ($j in $jobs) {
            try {
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
                if ($result.Status -eq 'DEGRADED') { $degraded = $true }
                foreach ($errorMessage in $result.Errors) { Write-DBLog $runtime.LogPath $j.Id $errorMessage 'WARN' }
                Write-DBLog $runtime.LogPath $j.Id "Local result: $($result.Status); published packages: $published."
            }
            catch { $failed = $true; Write-DBLog $runtime.LogPath $j.Id $_.Exception.Message 'ERROR' }
        }
        $maintenance = $true
        try { Remove-DBExpired -Configuration $c -Runtime $runtime }
        catch { $maintenance = $false; Write-DBLog $runtime.LogPath 'Retention' $_.Exception.Message 'ERROR' }
        Write-DBLog $runtime.LogPath 'Complete' "Failed=$failed; degraded=$degraded; maintenance=$maintenance."
        try { Publish-DBLog -Configuration $c -Runtime $runtime }
        catch { $failed = $true; Write-DBLog $runtime.LogPath 'LogUpload' $_.Exception.Message 'ERROR' }
        if ($failed -or ($degraded -and -not $maintenance)) { return 1 }
        if (-not $maintenance) { return 4 }
        if ($degraded) { return 5 }
        return 0
    }
    catch {
        if ($null -ne $runtime) { Write-DBLog $runtime.LogPath 'Execution' $_.Exception.Message 'ERROR' }
        else { Write-Error (Protect-DBMessage $_.Exception.Message) -ErrorAction Continue }
        return 1
    }
    finally {
        if ($null -ne $runtime) { Close-DBRuntime $runtime }
    }
}
Export-ModuleMember -Function Invoke-DBBackup
