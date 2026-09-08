Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Archive.psm1')

function New-SevenFiscalArchive {
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

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
        throw "Fiscal source directory was not found: $SourcePath"
    }

    $null = Get-ChildItem -LiteralPath $SourcePath -Force -ErrorAction Stop | Select-Object -First 1

    return New-SevenArchive `
        -SevenZipPath $SevenZipPath `
        -SourcePath $SourcePath `
        -ArchivePath $ArchivePath `
        -CompressionLevel $CompressionLevel `
        -CpuLimitPercent $CpuLimitPercent
}

Export-ModuleMember -Function New-SevenFiscalArchive
