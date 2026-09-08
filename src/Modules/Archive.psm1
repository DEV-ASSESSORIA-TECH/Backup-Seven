Set-StrictMode -Version Latest

function Invoke-SevenZip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SevenZipPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Arguments
    )

    if (-not (Test-Path -LiteralPath $SevenZipPath -PathType Leaf)) {
        throw "7-Zip executable was not found: $SevenZipPath"
    }

    $output = @(& $SevenZipPath @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    $exitCode = $LASTEXITCODE

    [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $output
    }
}

function Test-SevenArchive {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SevenZipPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ArchivePath
    )

    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        throw "Archive was not found: $ArchivePath"
    }

    $result = Invoke-SevenZip -SevenZipPath $SevenZipPath -Arguments @('t', '-y', $ArchivePath)
    if ($result.ExitCode -ne 0) {
        $details = $result.Output -join [Environment]::NewLine
        throw "7-Zip archive validation failed with exit code $($result.ExitCode). $details"
    }

    return $true
}

function New-SevenArchive {
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
        [int] $CpuLimitPercent = 50
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
    $arguments = @(
        'a'
        '-t7z'
        "-mx=$CompressionLevel"
        "-mmt=$threadCount"
        '-y'
        $ArchivePath
        $SourcePath
    )

    try {
        $result = Invoke-SevenZip -SevenZipPath $SevenZipPath -Arguments $arguments
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

        $null = Test-SevenArchive -SevenZipPath $SevenZipPath -ArchivePath $ArchivePath
        return Get-Item -LiteralPath $ArchivePath
    }
    catch {
        if (Test-Path -LiteralPath $ArchivePath -PathType Leaf) {
            Remove-Item -LiteralPath $ArchivePath -Force -ErrorAction SilentlyContinue
        }

        throw
    }
}

Export-ModuleMember -Function New-SevenArchive, Test-SevenArchive
