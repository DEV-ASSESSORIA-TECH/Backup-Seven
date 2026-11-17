Set-StrictMode -Version Latest

function Invoke-DBTool {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Executable, [Parameter(Mandatory)][string[]] $Arguments,
        [ValidateRange(0.05,86400)][double] $TimeoutSeconds = 21600, [string] $OutputPath)
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
            if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                $p.Kill($true)
                $null = $p.WaitForExit(10000)
                throw [TimeoutException]::new("External tool exceeded its $TimeoutSeconds second timeout; process tree terminated.")
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
Export-ModuleMember -Function Invoke-DBTool
