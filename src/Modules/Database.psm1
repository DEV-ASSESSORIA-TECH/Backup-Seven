Set-StrictMode -Version Latest

function New-SevenDatabaseDump {
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $MySqlDumpPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $DefaultsExtraFile,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $DatabaseName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $OutputPath,

        [string[]] $ExtraArguments = @()
    )

    if (-not (Test-Path -LiteralPath $MySqlDumpPath -PathType Leaf)) {
        throw "mysqldump executable was not found: $MySqlDumpPath"
    }

    if (-not (Test-Path -LiteralPath $DefaultsExtraFile -PathType Leaf)) {
        throw "MySQL defaults file was not found: $DefaultsExtraFile"
    }

    if (Test-Path -LiteralPath $OutputPath) {
        throw "Database dump destination already exists: $OutputPath"
    }

    foreach ($argument in $ExtraArguments) {
        if ($argument -match '^(--password(?:=|$)|-p.+)') {
            throw 'Database.ExtraArguments must not contain a password.'
        }
    }

    $outputDirectory = Split-Path -Parent $OutputPath
    if ([string]::IsNullOrWhiteSpace($outputDirectory)) {
        throw 'Database dump path must include a parent directory.'
    }

    $null = New-Item -ItemType Directory -Path $outputDirectory -Force
    $arguments = @(
        "--defaults-extra-file=$DefaultsExtraFile"
        '--single-transaction'
        '--quick'
        '--routines'
        '--events'
        '--triggers'
        '--databases'
        $DatabaseName
    ) + $ExtraArguments

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $MySqlDumpPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    foreach ($argument in $arguments) {
        $null = $startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $outputStream = $null

    try {
        if (-not $process.Start()) {
            throw 'mysqldump process could not be started.'
        }

        $stderrTask = $process.StandardError.ReadToEndAsync()
        $outputStream = [System.IO.File]::Create($OutputPath)
        $process.StandardOutput.BaseStream.CopyTo($outputStream)
        $outputStream.Dispose()
        $outputStream = $null

        $process.WaitForExit()
        $stderr = $stderrTask.GetAwaiter().GetResult().Trim()

        if ($process.ExitCode -ne 0) {
            throw "mysqldump failed with exit code $($process.ExitCode). $stderr"
        }

        $dump = Get-Item -LiteralPath $OutputPath
        if ($dump.Length -le 0) {
            throw "mysqldump created an empty dump: $OutputPath"
        }

        return $dump
    }
    catch {
        if ($null -ne $outputStream) {
            $outputStream.Dispose()
        }

        if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
            Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue
        }

        throw
    }
    finally {
        $process.Dispose()
    }
}

Export-ModuleMember -Function New-SevenDatabaseDump
