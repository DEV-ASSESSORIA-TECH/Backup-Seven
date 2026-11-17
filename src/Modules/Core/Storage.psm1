Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Process.psm1')

function Invoke-Rclone {
    param([string] $RclonePath, [string[]] $Arguments, [double] $TimeoutSeconds = 21600)
    Invoke-DBTool -Executable $RclonePath -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
}

function Test-DBStorageConfiguration {
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
        [string] $RemoteRoot,
        [double] $TimeoutSeconds = 21600
    )

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "rclone configuration was not found: $ConfigPath"
    }

    $remoteName = $RemoteRoot.Substring(0, $RemoteRoot.IndexOf(':') + 1)
    $result = Invoke-Rclone -RclonePath $RclonePath -TimeoutSeconds $TimeoutSeconds -Arguments @(
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

function Send-DBBackupFile {
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
        [string] $RemotePath,
        [double] $TimeoutSeconds = 21600
    )

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "rclone configuration was not found: $ConfigPath"
    }

    if (-not (Test-Path -LiteralPath $LocalPath -PathType Leaf)) {
        throw "Backup file was not found: $LocalPath"
    }

    $copyResult = Invoke-Rclone -RclonePath $RclonePath -TimeoutSeconds $TimeoutSeconds -Arguments @(
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
    $checkResult = Invoke-Rclone -RclonePath $RclonePath -TimeoutSeconds $TimeoutSeconds -Arguments @(
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

Export-ModuleMember -Function Test-DBStorageConfiguration, Send-DBBackupFile
