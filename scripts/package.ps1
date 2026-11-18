#requires -Version 7.2
[CmdletBinding()]
param([string] $OutputDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$version = (Get-Content -LiteralPath (Join-Path $repository 'VERSION') -Raw).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'VERSION must be X.Y.Z.' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repository 'dist' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$staging = Join-Path $temporaryRoot "DBBackup-package-$([guid]::NewGuid().ToString('N'))"
$temporaryZip = Join-Path $OutputDirectory "DBBackup-$version.build-$([guid]::NewGuid().ToString('N')).zip"
$zipPath = Join-Path $OutputDirectory "DBBackup-$version.zip"
$checksumTemp = "$zipPath.sha256.tmp"
try {
    $null = New-Item -ItemType Directory -Path $staging
    $entries = @(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'package.files.json') -Raw | ConvertFrom-Json)
    $targets = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $hashes = @{}
    foreach ($entry in $entries) {
        if ($entry.target -match '(^|/)\.\.?(/|$)|[\\:]' -or $entry.target.StartsWith('/') -or -not $targets.Add($entry.target)) { throw 'Unsafe or duplicate package target.' }
        $source = [IO.Path]::GetFullPath((Join-Path $repository $entry.source))
        if (-not $source.StartsWith($repository + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Package source escaped repository.' }
        $file = Get-Item -LiteralPath $source -Force
        if ($file.PSIsContainer -or $file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Package sources must be regular files.' }
        if ($entry.target -match '(?i)(^|/)(Secrets|Instances|Runtime|Pending|Completed|Logs)(/|$)|(^|/)config\.psd1$') { throw 'Operational state is forbidden in packages.' }
        $destination = Join-Path $staging $entry.target
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force
        Copy-Item -LiteralPath $source -Destination $destination
        $hash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
        if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -cne $hash) { throw 'Staged package file hash mismatch.' }
        $hashes[$entry.target] = $hash
    }
    # The only document at the package root: installed version, links to the
    # repository/runbook of this version and a short operator guide.
    $readme = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'LEIA-ME.template.txt') -Raw).Replace('{{VERSION}}', $version)
    $readme = ($readme -replace "`r?`n", "`r`n")
    $readmePath = Join-Path $staging 'LEIA-ME.txt'
    [IO.File]::WriteAllText($readmePath, $readme, [Text.UTF8Encoding]::new($true))
    if (-not $targets.Add('LEIA-ME.txt')) { throw 'LEIA-ME.txt is generated and cannot be listed.' }
    $hashes['LEIA-ME.txt'] = (Get-FileHash -LiteralPath $readmePath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.Compression.ZipFile]::CreateFromDirectory($staging,$temporaryZip,[IO.Compression.CompressionLevel]::Optimal,$false)
    $zip = [IO.Compression.ZipFile]::OpenRead($temporaryZip)
    try {
        $actual = @($zip.Entries | ForEach-Object { $_.FullName.Replace('\','/') })
        $expected = @($targets)
        if (@(Compare-Object ($expected | Sort-Object) ($actual | Sort-Object)).Count) { throw 'ZIP entry allowlist mismatch.' }
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName.Replace('\','/')
            $stream = $entry.Open()
            $sha = [Security.Cryptography.SHA256]::Create()
            try {
                $hash = [Convert]::ToHexString($sha.ComputeHash($stream)).ToLowerInvariant()
                if ($hash -cne $hashes[$name]) { throw 'ZIP file content hash mismatch.' }
            }
            finally { $stream.Dispose(); $sha.Dispose() }
        }
    }
    finally { $zip.Dispose() }
    $digest = (Get-FileHash -LiteralPath $temporaryZip -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($checksumTemp,"$digest  $([IO.Path]::GetFileName($zipPath))`n",[Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporaryZip,$zipPath,$true)
    [IO.File]::Move($checksumTemp,"$zipPath.sha256",$true)
    Get-Item -LiteralPath $zipPath
}
finally {
    foreach ($path in @($temporaryZip,$checksumTemp)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
    $resolved = [IO.Path]::GetFullPath($staging)
    if (-not $resolved.StartsWith($temporaryRoot.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolved) -notmatch '^DBBackup-package-[a-f0-9]{32}$') { throw 'Unsafe staging cleanup target.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
