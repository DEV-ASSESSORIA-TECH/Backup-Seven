Set-StrictMode -Version Latest
foreach ($module in @('Archive', 'Storage', 'Encryption', 'Runtime', 'Configuration')) { Import-Module (Join-Path $PSScriptRoot "$module.psm1") }

function Assert-DBBackupDependency {
    param([Collections.IDictionary] $Configuration, [object[]] $Jobs)
    $paths = @($Configuration.Tools.SevenZip, $Configuration.Tools.Age, $Configuration.Tools.Rclone, $Configuration.Storage.ConfigPath)
    foreach ($j in $Jobs) {
        switch ($j.Provider) {
            MySQL { $paths += @($Configuration.Tools.MySql, $Configuration.Tools.MySqlDump, $Configuration.Database.DefaultsExtraFile) }
            SQLAnywhere { $paths += @($Configuration.Tools.DbBackup, $Configuration.Tools.DbValid, $Configuration.Tools.DbEngine, $Configuration.Database.ConnectionOptionsFile) }
            Directory { if (-not (Test-Path -LiteralPath $j.SourcePath -PathType Container)) { throw 'Directory source is missing.' } }
        }
    }
    foreach ($path in $paths) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required dependency is missing: $path" } }
    $null = Read-DBRecipient $Configuration.Encryption.RecipientsFile
    $null = Test-DBStorageConfiguration -RclonePath $Configuration.Tools.Rclone -ConfigPath $Configuration.Storage.ConfigPath -RemoteRoot $Configuration.Storage.RemoteRoot
}

function Write-DBJson {
    param([string] $Path, $Value)
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $temp -Encoding utf8 -ErrorAction Stop
        [IO.File]::Move($temp, $Path, $true)
    }
    finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}

function Read-DBArtifact {
    param([string] $BundlePath, [Collections.IDictionary] $Configuration)
    if ((Get-Item -LiteralPath $BundlePath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Artifact bundle cannot be a link.' }
    $statePath = Join-Path $BundlePath 'state.json'
    if ((Get-Item -LiteralPath $statePath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Artifact state cannot be a link.' }
    $s = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if ($s.SchemaVersion -ne 1 -or $s.Instance -cne $Configuration.InstanceName) { throw 'Artifact schema or ownership mismatch.' }
    Assert-DBIdentifier $s.Job
    if ($s.FileName -notmatch '^DBBackup_[A-Za-z0-9_-]+\.7z\.age$' -or [IO.Path]::GetFileName($s.FileName) -cne $s.FileName) { throw 'Unsafe artifact file name.' }
    if ($s.RemotePath -notmatch '^[A-Za-z0-9_-]+:[^\r\n]+$' -or -not $s.RemotePath.EndsWith('/' + $s.FileName, [StringComparison]::Ordinal)) { throw 'Invalid recorded remote destination.' }
    $payload = Join-Path $BundlePath $s.FileName
    $item = Get-Item -LiteralPath $payload -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Artifact payload cannot be a link.' }
    if ($item.Length -ne $s.SizeBytes -or (Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash -cne $s.Sha256) { throw 'Encrypted artifact integrity mismatch.' }
    $null = [DateTime]::Parse($s.RecoveryPointUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    return $s
}

function Send-DBBundle {
    param([Collections.IDictionary] $Configuration, $Runtime, [string] $BundlePath)
    $s = Read-DBArtifact $BundlePath $Configuration
    $destination = Join-Path (Join-Path $Runtime.Completed $s.Job) (Split-Path -Leaf $BundlePath)
    if (Test-Path -LiteralPath $destination) { throw 'Completed bundle already exists; refusing overwrite.' }
    $null = Send-DBBackupFile -RclonePath $Configuration.Tools.Rclone -ConfigPath $Configuration.Storage.ConfigPath -LocalPath (Join-Path $BundlePath $s.FileName) -RemotePath $s.RemotePath
    $s.Transport = 'CONFIRMED'
    Write-DBJson (Join-Path $BundlePath 'state.json') $s
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force
    # Configuration requires the same volume: never split payload and state
    # with a cross-volume copy/delete when confirming transport.
    [IO.Directory]::Move($BundlePath, $destination)
}

function Publish-DBPackage {
    param([Collections.IDictionary] $Configuration, $Runtime, $Job, $Result, $Package)
    $stamp = $Result.StartedAtUtc.ToString('yyyyMMddTHHmmssZ')
    Assert-DBIdentifier $Package.Role
    $base = "DBBackup_${stamp}_$($Configuration.InstanceName)_$($Job.Id)_$($Runtime.RunId)_$($Package.Role)"
    $source = [IO.Path]::GetFullPath($Package.SourcePath)
    if (-not (Test-DBPathWithin $source $Runtime.Work)) { throw 'Provider payload is outside run work directory.' }
    $manifestPath = Join-Path $source 'manifest.json'
    if (Test-Path -LiteralPath $manifestPath) { throw 'Provider payload contains reserved manifest.json.' }
    $files = @()
    foreach ($file in Get-ChildItem -LiteralPath $source -Recurse -Force -ErrorAction Stop) {
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Payload contains a link.' }
        if (-not $file.PSIsContainer) {
            $files += @{ Path = [IO.Path]::GetRelativePath($source, $file.FullName).Replace('\','/'); SizeBytes = $file.Length; Sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash }
        }
    }
    $versions = @{}
    $toolKeys = @('SevenZip', 'Age', 'Rclone')
    if ($Job.Provider -eq 'MySQL') { $toolKeys += @('MySql', 'MySqlDump') }
    if ($Job.Provider -eq 'SQLAnywhere') { $toolKeys += @('DbBackup', 'DbValid', 'DbEngine') }
    foreach ($key in $toolKeys) {
        $tool = Get-Item -LiteralPath $Configuration.Tools[$key] -ErrorAction Stop
        $versions[$key] = @{ FileVersion = $tool.VersionInfo.FileVersion; Sha256 = (Get-FileHash -LiteralPath $tool.FullName -Algorithm SHA256).Hash }
    }
    Write-DBJson $manifestPath @{
        SchemaVersion = 1; Producer = 'dbbackup'; Provider = $Job.Provider; Instance = $Configuration.InstanceName
        Job = $Job.Id; RunId = $Runtime.RunId; Role = $Package.Role; Status = $Result.Status
        StartedAtUtc = $Result.StartedAtUtc.ToString('o'); FinishedAtUtc = $Result.FinishedAtUtc.ToString('o')
        Metadata = $Result.Metadata; Files = $files; Tools = $versions
        Roles = @($Result.Packages.Role)
    }
    $archive = Join-Path $Runtime.Work "$base.7z"
    $null = New-DBArchive -SevenZipPath $Configuration.Tools.SevenZip -SourcePath $source -ArchivePath $archive -ContentsOnly `
        -CompressionLevel $Configuration.Archive.CompressionLevel -CpuLimitPercent $Configuration.Archive.CpuLimitPercent
    $bundle = Join-Path $Runtime.Staging $base
    Set-DBPrivateDirectory $bundle
    try {
        $temp = Join-Path $bundle 'payload.tmp'
        Protect-DBArchive -AgePath $Configuration.Tools.Age -InputPath $archive -OutputPath $temp -RecipientsFile $Configuration.Encryption.RecipientsFile
        $name = "$base.7z.age"
        $payload = Join-Path $bundle $name
        Move-Item -LiteralPath $temp -Destination $payload -ErrorAction Stop
        $remote = '{0}/{1}/{2}/{3}/{4}' -f $Configuration.Storage.RemoteRoot.TrimEnd('/'), $Configuration.InstanceName, $Job.Id, $Result.StartedAtUtc.ToString('yyyy/MM/dd'), $name
        Write-DBJson (Join-Path $bundle 'state.json') @{
            SchemaVersion = 1; Instance = $Configuration.InstanceName; Job = $Job.Id; RunId = $Runtime.RunId
            Role = $Package.Role; LocalStatus = $Result.Status; RecoveryPointUtc = $Result.StartedAtUtc.ToString('o')
            FileName = $name; SizeBytes = (Get-Item -LiteralPath $payload).Length
            Sha256 = (Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash; RemotePath = $remote; Transport = 'PENDING'
        }
        $pendingParent = Join-Path $Runtime.Pending $Job.Id
        $null = New-Item -ItemType Directory -Path $pendingParent -Force
        $pending = Join-Path $pendingParent $base
        [IO.Directory]::Move($bundle, $pending)
        Send-DBBundle -Configuration $Configuration -Runtime $Runtime -BundlePath $pending
    }
    finally {
        if (Test-Path -LiteralPath $bundle) { Remove-Item -LiteralPath $bundle -Recurse -Force }
        if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    }
}

function Invoke-DBPendingRetry {
    param([Collections.IDictionary] $Configuration, $Runtime, [string] $Job)
    $parent = Join-Path $Runtime.Pending $Job
    if (-not (Test-Path -LiteralPath $parent)) { return $true }
    $ok = $true
    foreach ($bundle in Get-ChildItem -LiteralPath $parent -Directory | Sort-Object Name) {
        try {
            $state = Read-DBArtifact $bundle.FullName $Configuration
            if ($state.Job -cne $Job) { throw 'Pending job mismatch.' }
            Send-DBBundle -Configuration $Configuration -Runtime $Runtime -BundlePath $bundle.FullName
        }
        catch { $ok = $false; Write-DBLog $Runtime.LogPath $Job $_.Exception.Message 'ERROR' }
    }
    return $ok
}

function Remove-DBExpired {
    param([Collections.IDictionary] $Configuration, $Runtime)
    foreach ($job in $Configuration.Jobs) {
        $parent = Join-Path $Runtime.Completed $job.Id
        if (-not (Test-Path -LiteralPath $parent)) { continue }
        foreach ($bundle in Get-ChildItem -LiteralPath $parent -Directory) {
            $state = Read-DBArtifact $bundle.FullName $Configuration
            if ($state.Job -cne $job.Id -or $state.Transport -cne 'CONFIRMED') { throw 'Completed state mismatch.' }
            if (([DateTime] $state.RecoveryPointUtc).ToUniversalTime() -lt [DateTime]::UtcNow.AddDays(-[int] $Configuration.Retention.CompletedDays)) {
                Remove-Item -LiteralPath $bundle.FullName -Recurse -Force -ErrorAction Stop
            }
        }
    }
    foreach ($log in Get-ChildItem -LiteralPath $Configuration.Paths.LogRoot -File -Filter 'DBBackupLog_*.log') {
        if ($log.FullName -eq $Runtime.LogPath -or $log.Name -notmatch '^DBBackupLog_(\d{8}T\d{6}Z)_[a-f0-9]{32}\.log$') { continue }
        $date = [DateTime]::ParseExact($Matches[1], 'yyyyMMddTHHmmssZ', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime()
        if ($date -lt [DateTime]::UtcNow.AddDays(-[int] $Configuration.Retention.LogDays)) { Remove-Item -LiteralPath $log.FullName -Force -ErrorAction Stop }
    }
}

function Publish-DBLog {
    param([Collections.IDictionary] $Configuration, $Runtime)
    $remote = '{0}/{1}/Logs/{2}/{3}' -f $Configuration.Storage.RemoteRoot.TrimEnd('/'), $Configuration.InstanceName, [DateTime]::UtcNow.ToString('yyyy/MM/dd'), [IO.Path]::GetFileName($Runtime.LogPath)
    $null = Send-DBBackupFile -RclonePath $Configuration.Tools.Rclone -ConfigPath $Configuration.Storage.ConfigPath -LocalPath $Runtime.LogPath -RemotePath $remote
}

Export-ModuleMember -Function Assert-DBBackupDependency, Publish-DBPackage, Invoke-DBPendingRetry, Remove-DBExpired, Publish-DBLog, Read-DBArtifact
