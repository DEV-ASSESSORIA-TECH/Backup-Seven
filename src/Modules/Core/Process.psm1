Set-StrictMode -Version Latest

function Invoke-DBTool {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Executable, [Parameter(Mandatory)][string[]] $Arguments)
    $si = [Diagnostics.ProcessStartInfo]::new()
    $si.FileName = $Executable
    $si.UseShellExecute = $false
    $si.CreateNoWindow = $true
    $si.RedirectStandardOutput = $true
    $si.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $si.ArgumentList.Add($argument) }
    $p = [Diagnostics.Process]::new()
    $p.StartInfo = $si
    try {
        if (-not $p.Start()) { throw 'External tool did not start.' }
        $stdout = $p.StandardOutput.ReadToEndAsync()
        $stderr = $p.StandardError.ReadToEndAsync()
        $p.WaitForExit()
        [pscustomobject]@{ ExitCode = $p.ExitCode; StdOut = $stdout.GetAwaiter().GetResult(); StdErr = $stderr.GetAwaiter().GetResult() }
    }
    finally { $p.Dispose() }
}
Export-ModuleMember -Function Invoke-DBTool
