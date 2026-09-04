#requires -Version 7.0

[CmdletBinding()]
param(
    [string] $OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$sourceRoot = Join-Path $repositoryRoot 'src'
$mysqlTemplatePath = Join-Path $sourceRoot 'Secrets/mysql-backup.example.cnf'
$versionPath = Join-Path $repositoryRoot 'VERSION'
$stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("BackupSeven-package-$([guid]::NewGuid().ToString('N'))")

try {
    if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
        throw "VERSION file was not found: $versionPath"
    }

    $version = (Get-Content -LiteralPath $versionPath -Raw).Trim()
    if ($version -notmatch '^\d+\.\d+\.\d+$') {
        throw "VERSION must use X.Y.Z format: $version"
    }

    if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        $OutputDirectory = Join-Path $repositoryRoot 'dist'
    }
    elseif (-not [System.IO.Path]::IsPathFullyQualified($OutputDirectory)) {
        $OutputDirectory = Join-Path $repositoryRoot $OutputDirectory
    }

    $requiredSources = @(
        (Join-Path $sourceRoot 'Backup-Seven.ps1')
        (Join-Path $sourceRoot 'config.example.psd1')
        $mysqlTemplatePath
        (Join-Path $repositoryRoot 'README.md')
        $versionPath
    )

    foreach ($requiredSource in $requiredSources) {
        if (-not (Test-Path -LiteralPath $requiredSource -PathType Leaf)) {
            throw "Required package source was not found: $requiredSource"
        }
    }

    $moduleSource = Join-Path $sourceRoot 'Modules'
    $moduleFiles = @(Get-ChildItem -LiteralPath $moduleSource -Filter '*.psm1' -File | Sort-Object Name)
    if ($moduleFiles.Count -eq 0) {
        throw "No PowerShell modules were found in: $moduleSource"
    }

    $null = New-Item -ItemType Directory -Path $stagingRoot -Force
    $stagingModules = Join-Path $stagingRoot 'Modules'
    $stagingSecrets = Join-Path $stagingRoot 'Secrets'
    $null = New-Item -ItemType Directory -Path $stagingModules -Force
    $null = New-Item -ItemType Directory -Path $stagingSecrets -Force

    Copy-Item -LiteralPath (Join-Path $sourceRoot 'Backup-Seven.ps1') -Destination $stagingRoot
    Copy-Item `
        -LiteralPath (Join-Path $sourceRoot 'config.example.psd1') `
        -Destination (Join-Path $stagingRoot 'config.psd1')
    Copy-Item `
        -LiteralPath $mysqlTemplatePath `
        -Destination (Join-Path $stagingSecrets 'mysql-backup.cnf')
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'README.md') -Destination $stagingRoot
    Copy-Item -LiteralPath $versionPath -Destination $stagingRoot
    foreach ($moduleFile in $moduleFiles) {
        Copy-Item -LiteralPath $moduleFile.FullName -Destination $stagingModules
    }

    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
    $archivePath = Join-Path $OutputDirectory "BackupSeven-$version.zip"
    $checksumPath = "$archivePath.sha256"
    if (Test-Path -LiteralPath $archivePath) {
        Remove-Item -LiteralPath $archivePath -Force
    }
    if (Test-Path -LiteralPath $checksumPath) {
        Remove-Item -LiteralPath $checksumPath -Force
    }

    Compress-Archive -Path (Join-Path $stagingRoot '*') -DestinationPath $archivePath -CompressionLevel Optimal

    $expectedEntries = @(
        'Backup-Seven.ps1'
        'config.psd1'
        'README.md'
        'Secrets/mysql-backup.cnf'
        'VERSION'
    ) + @($moduleFiles | ForEach-Object { "Modules/$($_.Name)" })

    $zip = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        $actualEntries = @(
            $zip.Entries |
                Where-Object { -not $_.FullName.EndsWith('/') } |
                ForEach-Object { $_.FullName.Replace('\', '/') } |
                Sort-Object
        )
    }
    finally {
        $zip.Dispose()
    }

    $differences = @(Compare-Object ($expectedEntries | Sort-Object) $actualEntries)
    if ($differences.Count -gt 0) {
        $details = $differences | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }
        throw "Package content validation failed. $($details -join '; ')"
    }

    $hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $([System.IO.Path]::GetFileName($archivePath))" |
        Set-Content -LiteralPath $checksumPath -Encoding ascii

    $recordedHash = ((Get-Content -LiteralPath $checksumPath -Raw).Trim() -split '\s+')[0]
    if ($recordedHash -ne $hash) {
        throw "SHA256 validation failed for package: $archivePath"
    }

    Get-Item -LiteralPath $archivePath
}
finally {
    $resolvedStaging = [System.IO.Path]::GetFullPath($stagingRoot)
    $resolvedTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $safePrefix = 'BackupSeven-package-'
    if (
        $resolvedStaging.StartsWith($resolvedTemp, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedStaging).StartsWith($safePrefix, [System.StringComparison]::Ordinal) -and
        (Test-Path -LiteralPath $resolvedStaging)
    ) {
        Remove-Item -LiteralPath $resolvedStaging -Recurse -Force
    }
}
