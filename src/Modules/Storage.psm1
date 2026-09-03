Set-StrictMode -Version Latest

function Invoke-Rclone {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $RclonePath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Arguments
    )

    if (-not (Test-Path -LiteralPath $RclonePath -PathType Leaf)) {
        throw "rclone executable was not found: $RclonePath"
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $RclonePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    foreach ($argument in $Arguments) {
        $null = $startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo

    try {
        if (-not $process.Start()) {
            throw 'rclone process could not be started.'
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()

        [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut   = $stdoutTask.GetAwaiter().GetResult().Trim()
            StdErr   = $stderrTask.GetAwaiter().GetResult().Trim()
        }
    }
    finally {
        $process.Dispose()
    }
}

function Test-SevenStorageConfiguration {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $RclonePath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ConfigPath,

        [Parameter(Mandatory)]
        [ValidatePattern('^[^:]+:.+')]
        [string] $RemoteRoot
    )

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "rclone configuration was not found: $ConfigPath"
    }

    $remoteName = $RemoteRoot.Substring(0, $RemoteRoot.IndexOf(':') + 1)
    $result = Invoke-Rclone -RclonePath $RclonePath -Arguments @(
        'listremotes'
        '--config'
        $ConfigPath
    )

    if ($result.ExitCode -ne 0) {
        throw "rclone could not read its configuration (exit code $($result.ExitCode)). $($result.StdErr)"
    }

    $remotes = @($result.StdOut -split '[\r\n]+' | Where-Object { $_ })
    if ($remoteName -notin $remotes) {
        throw "rclone remote '$remoteName' was not found in $ConfigPath"
    }

    return $true
}

function Send-SevenBackupFile {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $RclonePath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ConfigPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $LocalPath,

        [Parameter(Mandatory)]
        [ValidatePattern('^[^:]+:.+')]
        [string] $RemotePath
    )

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "rclone configuration was not found: $ConfigPath"
    }

    if (-not (Test-Path -LiteralPath $LocalPath -PathType Leaf)) {
        throw "Backup file was not found: $LocalPath"
    }

    $copyResult = Invoke-Rclone -RclonePath $RclonePath -Arguments @(
        'copyto'
        $LocalPath
        $RemotePath
        '--config'
        $ConfigPath
    )

    if ($copyResult.ExitCode -ne 0) {
        throw "rclone copyto failed with exit code $($copyResult.ExitCode). $($copyResult.StdErr)"
    }

    $remoteSeparator = $RemotePath.LastIndexOf('/')
    if ($remoteSeparator -le $RemotePath.IndexOf(':')) {
        throw "Remote backup path must include a directory: $RemotePath"
    }

    $localDirectory = Split-Path -Parent $LocalPath
    $fileName = Split-Path -Leaf $LocalPath
    $remoteDirectory = $RemotePath.Substring(0, $remoteSeparator)
    $checkResult = Invoke-Rclone -RclonePath $RclonePath -Arguments @(
        'check'
        $localDirectory
        $remoteDirectory
        '--config'
        $ConfigPath
        '--one-way'
        '--include'
        "/$fileName"
    )

    if ($checkResult.ExitCode -ne 0) {
        throw "rclone check failed with exit code $($checkResult.ExitCode). $($checkResult.StdErr)"
    }

    return $RemotePath
}

Export-ModuleMember -Function Test-SevenStorageConfiguration, Send-SevenBackupFile
