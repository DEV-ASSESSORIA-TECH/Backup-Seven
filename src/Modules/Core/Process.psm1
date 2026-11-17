Set-StrictMode -Version Latest

# The run deadline is process-wide (not module-scoped) so every module that
# imports this file observes the same limit, regardless of import order.
$script:DeadlineKey = 'DBBackup.ToolDeadlineUtc'

function Set-DBToolDeadline {
    param([Nullable[DateTime]] $DeadlineUtc)
    [AppDomain]::CurrentDomain.SetData($script:DeadlineKey, $(if ($null -ne $DeadlineUtc) { $DeadlineUtc.ToUniversalTime() } else { $null }))
}

function Get-DBToolDeadline {
    $value = [AppDomain]::CurrentDomain.GetData($script:DeadlineKey)
    if ($value -is [DateTime]) { return $value }
    return $null
}

function Assert-DBToolDeadline {
    $deadline = Get-DBToolDeadline
    if ($null -ne $deadline -and [DateTime]::UtcNow -ge $deadline) {
        throw [TimeoutException]::new('Run deadline exceeded (Execution.RunTimeoutSeconds); remaining work was not started.')
    }
}

function Invoke-DBTool {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Executable, [Parameter(Mandatory)][string[]] $Arguments,
        [ValidateRange(0.05,86400)][double] $TimeoutSeconds = 21600, [string] $OutputPath)
    # Never let a single tool outlive the run deadline: the scheduler limit is
    # set above it so the run can still record failure and clean up.
    Assert-DBToolDeadline
    $limit = $TimeoutSeconds
    $deadline = Get-DBToolDeadline
    if ($null -ne $deadline) { $limit = [Math]::Max(0.05, [Math]::Min($limit, ($deadline - [DateTime]::UtcNow).TotalSeconds)) }
    $si = [Diagnostics.ProcessStartInfo]::new()
    $si.FileName = $Executable
    $si.UseShellExecute = $false
    $si.CreateNoWindow = $true
    $si.RedirectStandardOutput = $true
    $si.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $si.ArgumentList.Add($argument) }
    $p = [Diagnostics.Process]::new()
    $p.StartInfo = $si
    $stream = $null
    $started = $false
    try {
        if ($OutputPath) {
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $OutputPath) -Force
            $stream = [IO.File]::Open($OutputPath, 'CreateNew', 'Write', 'None')
        }
        if (-not $p.Start()) { throw 'External tool did not start.' }
        $started = $true
        $stdout = if ($null -ne $stream) { $p.StandardOutput.BaseStream.CopyToAsync($stream) } else { $p.StandardOutput.ReadToEndAsync() }
        $stderr = $p.StandardError.ReadToEndAsync()
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while (-not $p.WaitForExit(100)) {
            if ($stdout.IsFaulted) { $null = $stdout.GetAwaiter().GetResult() }
            if ($watch.Elapsed.TotalSeconds -ge $limit) {
                $p.Kill($true)
                $null = $p.WaitForExit(10000)
                $reason = if ($limit -lt $TimeoutSeconds) { 'the run deadline' } else { "its $TimeoutSeconds second timeout" }
                throw [TimeoutException]::new("External tool exceeded $reason; process tree terminated.")
            }
        }
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]] @($stdout,$stderr), 10000)) {
            throw 'External tool output pipes did not close.'
        }
        $output = if ($null -eq $stream) { $stdout.GetAwaiter().GetResult() } else { $null }
        $errorText = $stderr.GetAwaiter().GetResult()
        if ($null -ne $stream) { $stream.Dispose(); $stream = $null }
        [pscustomobject]@{
            ExitCode = $p.ExitCode; StdOut = $output; StdErr = $errorText
            File = if ($OutputPath) { Get-Item -LiteralPath $OutputPath } else { $null }
        }
    }
    finally {
        if ($started -and -not $p.HasExited) { $p.Kill($true); $null = $p.WaitForExit(10000) }
        if ($null -ne $stream) { $stream.Dispose() }
        $p.Dispose()
    }
}
Export-ModuleMember -Function Invoke-DBTool, Set-DBToolDeadline, Get-DBToolDeadline, Assert-DBToolDeadline
