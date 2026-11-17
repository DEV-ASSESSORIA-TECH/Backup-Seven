Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Process.psm1')

function Invoke-DBZip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SevenZipPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Arguments,
        [double] $TimeoutSeconds = 21600
    )

    if (-not (Test-Path -LiteralPath $SevenZipPath -PathType Leaf)) {
        throw "7-Zip executable was not found: $SevenZipPath"
    }

    $r = Invoke-DBTool -Executable $SevenZipPath -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
    [pscustomobject]@{ExitCode=$r.ExitCode;Output=@($r.StdOut,$r.StdErr)}
}

function Test-DBArchive {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SevenZipPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ArchivePath,
        [double] $TimeoutSeconds = 21600
    )

    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        throw "Archive was not found: $ArchivePath"
    }

    $result = Invoke-DBZip -SevenZipPath $SevenZipPath -TimeoutSeconds $TimeoutSeconds -Arguments @('t', '-y', $ArchivePath)
    if ($result.ExitCode -ne 0) {
        $details = $result.Output -join [Environment]::NewLine
        throw "7-Zip archive validation failed with exit code $($result.ExitCode). $details"
    }

    return $true
}

function New-DBArchive {
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SevenZipPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SourcePath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ArchivePath,

        [ValidateRange(0, 9)]
        [int] $CompressionLevel = 5,

        [ValidateRange(1, 100)]
        [int] $CpuLimitPercent = 50,

        [switch] $ContentsOnly,
        [double] $TimeoutSeconds = 21600
    )

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        throw "Archive source was not found: $SourcePath"
    }

    if ([System.IO.Path]::GetExtension($ArchivePath) -ne '.7z') {
        throw "Archive path must use the .7z extension: $ArchivePath"
    }

    if (Test-Path -LiteralPath $ArchivePath) {
        throw "Archive destination already exists: $ArchivePath"
    }

    $archiveDirectory = Split-Path -Parent $ArchivePath
    if ([string]::IsNullOrWhiteSpace($archiveDirectory)) {
        throw 'Archive path must include a parent directory.'
    }

    $null = New-Item -ItemType Directory -Path $archiveDirectory -Force
    [int] $threadCount = [Math]::Max(
        1,
        [Math]::Floor([Environment]::ProcessorCount * ($CpuLimitPercent / 100.0))
    )
    $archiveSource = $SourcePath
    if ($ContentsOnly -and (Test-Path -LiteralPath $SourcePath -PathType Container)) {
        $archiveSource = Join-Path $SourcePath '*'
    }
    $arguments = @(
        'a'
        '-t7z'
        "-mx=$CompressionLevel"
        "-mmt=$threadCount"
        '-y'
        $ArchivePath
        $archiveSource
    )

    try {
        $result = Invoke-DBZip -SevenZipPath $SevenZipPath -TimeoutSeconds $TimeoutSeconds -Arguments $arguments
        if ($result.ExitCode -ne 0) {
            $details = $result.Output -join [Environment]::NewLine
            throw "7-Zip archive creation failed with exit code $($result.ExitCode). $details"
        }

        if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
            throw "7-Zip reported success but did not create the archive: $ArchivePath"
        }

        $archive = Get-Item -LiteralPath $ArchivePath
        if ($archive.Length -le 0) {
            throw "7-Zip created an empty archive: $ArchivePath"
        }

        $null = Test-DBArchive -SevenZipPath $SevenZipPath -ArchivePath $ArchivePath -TimeoutSeconds $TimeoutSeconds
        return Get-Item -LiteralPath $ArchivePath
    }
    catch {
        if (Test-Path -LiteralPath $ArchivePath -PathType Leaf) {
            Remove-Item -LiteralPath $ArchivePath -Force -ErrorAction SilentlyContinue
        }

        throw
    }
}

Export-ModuleMember -Function New-DBArchive, Test-DBArchive
