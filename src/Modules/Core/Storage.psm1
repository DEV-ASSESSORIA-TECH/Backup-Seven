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

function Get-DBFileDigest {
    <# SHA-256 and MD5 of a file in a single read (MD5 is what S3 reports remotely). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)
    $sha = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    $md5 = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::MD5)
    $stream = [IO.File]::Open($Path, 'Open', 'Read', 'Read')
    try {
        $buffer = [byte[]]::new(1048576)
        [long] $length = 0
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $sha.AppendData($buffer, 0, $read)
            $md5.AppendData($buffer, 0, $read)
            $length += $read
        }
        [pscustomobject]@{
            Length = $length
            Sha256 = [Convert]::ToHexString($sha.GetHashAndReset())
            Md5    = [Convert]::ToHexString($md5.GetHashAndReset()).ToLowerInvariant()
        }
    }
    finally { $stream.Dispose(); $sha.Dispose(); $md5.Dispose() }
}

function Send-DBBackupFile {
    <#
    Uploads with copyto and verifies the remote object from its listing (size
    and, when the backend reports one, MD5), without reading the local file
    again. ExpectedSize/ExpectedMd5 come from the single digest pass made when
    the artifact was created; when absent they are computed here.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
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
        [Nullable[long]] $ExpectedSize,
        [string] $ExpectedMd5,
        [double] $TimeoutSeconds = 21600
    )

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "rclone configuration was not found: $ConfigPath"
    }

    if (-not (Test-Path -LiteralPath $LocalPath -PathType Leaf)) {
        throw "Backup file was not found: $LocalPath"
    }

    $remoteSeparator = $RemotePath.LastIndexOf('/')
    if ($remoteSeparator -le $RemotePath.IndexOf(':')) {
        throw "Remote backup path must include a directory: $RemotePath"
    }

    if ($null -eq $ExpectedSize -or [string]::IsNullOrWhiteSpace($ExpectedMd5)) {
        $digest = Get-DBFileDigest -Path $LocalPath
        $ExpectedSize = $digest.Length
        $ExpectedMd5 = $digest.Md5
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

    $fileName = $RemotePath.Substring($remoteSeparator + 1)
    $remoteDirectory = $RemotePath.Substring(0, $remoteSeparator)
    # Listing the dated directory (few objects) works on every rclone version;
    # remote hashes such as S3 MD5 come from object metadata, not a download.
    $listResult = Invoke-Rclone -RclonePath $RclonePath -TimeoutSeconds $TimeoutSeconds -Arguments @(
        'lsjson'
        $remoteDirectory
        '--config'
        $ConfigPath
        '--files-only'
        '--no-mimetype'
        '--hash'
        '--include'
        "/$fileName"
    )

    if ($listResult.ExitCode -ne 0) {
        throw "Remote verification failed: rclone lsjson exit code $($listResult.ExitCode). $($listResult.StdErr)"
    }

    $entries = @()
    $listing = [string] $listResult.StdOut
    if (-not [string]::IsNullOrWhiteSpace($listing)) {
        try { $entries = @($listing | ConvertFrom-Json) }
        catch { throw 'Remote verification failed: rclone lsjson returned invalid JSON.' }
    }
    $entry = @($entries | Where-Object { $null -ne $_ -and [string] $_.Name -ceq $fileName })
    if ($entry.Count -ne 1) { throw "Remote verification failed: uploaded object was not listed: $RemotePath" }
    if ([long] $entry[0].Size -ne [long] $ExpectedSize) {
        throw "Remote verification failed: size mismatch for $RemotePath (local $ExpectedSize, remote $($entry[0].Size))."
    }

    $remoteMd5 = $null
    $hashes = $entry[0].PSObject.Properties['Hashes']
    if ($null -ne $hashes -and $null -ne $hashes.Value) {
        foreach ($property in $hashes.Value.PSObject.Properties) {
            if ($property.Name -ieq 'md5' -and -not [string]::IsNullOrWhiteSpace([string] $property.Value)) { $remoteMd5 = ([string] $property.Value).ToLowerInvariant() }
        }
    }
    if ($null -ne $remoteMd5 -and $remoteMd5 -cne $ExpectedMd5.ToLowerInvariant()) {
        throw "Remote verification failed: MD5 mismatch for $RemotePath."
    }

    [pscustomobject]@{
        RemotePath   = $RemotePath
        Verification = if ($null -ne $remoteMd5) { 'size+md5' } else { 'size-only' }
    }
}

Export-ModuleMember -Function Test-DBStorageConfiguration, Get-DBFileDigest, Send-DBBackupFile
