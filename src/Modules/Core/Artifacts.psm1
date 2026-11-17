Set-StrictMode -Version Latest
foreach ($module in @('Archive', 'Storage', 'Encryption', 'Runtime', 'Configuration', 'Capacity', 'Observation')) { Import-Module (Join-Path $PSScriptRoot "$module.psm1") }

function Assert-DBBackupDependency {
    param([Collections.IDictionary] $Configuration, [object[]] $Jobs)
    $paths = @($Configuration.Tools.SevenZip, $Configuration.Tools.Age, $Configuration.Tools.Rclone, $Configuration.Storage.ConfigPath)
    foreach ($j in $Jobs) {
        switch ($j.Provider) {
            MySQL { $paths += @($Configuration.Tools.MySql, $Configuration.Tools.MySqlDump, $Configuration.Database.DefaultsExtraFile) }
            SQLAnywhere { $paths += @($Configuration.Tools.DbBackup, $Configuration.Database.ConnectionOptionsFile) }
            Directory { if (-not (Test-Path -LiteralPath $j.SourcePath -PathType Container)) { throw 'Directory source is missing.' } }
        }
    }
    foreach ($path in $paths) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required dependency is missing: $path" } }
    $null = Read-DBRecipient $Configuration.Encryption.RecipientsFile
    $null = Test-DBStorageConfiguration -RclonePath $Configuration.Tools.Rclone -ConfigPath $Configuration.Storage.ConfigPath -RemoteRoot $Configuration.Storage.RemoteRoot -TimeoutSeconds $Configuration.Execution.ToolTimeoutSeconds
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

function Test-DBLocalPayloadRemoved {
    param($State)
    $property = $State.PSObject.Properties['LocalPayload']
    return ($null -ne $property -and $property.Value -ceq 'REMOVED')
}

function Read-DBArtifact {
    <#
    -SkipPayloadHash checks ownership, names, payload presence and size only.
    Used where the bytes are not about to be sent: retention decides by state,
    and a bundle created moments ago in this run was already digested.
    #>
    param([string] $BundlePath, [Collections.IDictionary] $Configuration, [switch] $SkipPayloadHash)
    if ((Get-Item -LiteralPath $BundlePath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Artifact bundle cannot be a link.' }
    $statePath = Join-Path $BundlePath 'state.json'
    if ((Get-Item -LiteralPath $statePath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Artifact state cannot be a link.' }
    $s = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if ($s.SchemaVersion -ne 1 -or $s.Instance -cne $Configuration.InstanceName) { throw 'Artifact schema or ownership mismatch.' }
    Assert-DBIdentifier $s.Job
    if ($s.FileName -notmatch '^DBBackup_[A-Za-z0-9_-]+\.7z\.age$' -or [IO.Path]::GetFileName($s.FileName) -cne $s.FileName) { throw 'Unsafe artifact file name.' }
    if ($s.RemotePath -notmatch '^[A-Za-z0-9_-]+:[^\r\n]+$' -or -not $s.RemotePath.EndsWith('/' + $s.FileName, [StringComparison]::Ordinal)) { throw 'Invalid recorded remote destination.' }
    if (Test-DBLocalPayloadRemoved $s) {
        # Retention.KeepLocalPayload = $false: only confirmed bundles may drop
        # their local copy; the state keeps size/hash of the uploaded bytes.
        if ($s.Transport -cne 'CONFIRMED') { throw 'Only confirmed artifacts can omit the local payload.' }
    }
    else {
        $payload = Join-Path $BundlePath $s.FileName
        $item = Get-Item -LiteralPath $payload -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Artifact payload cannot be a link.' }
        if ($item.Length -ne $s.SizeBytes) { throw 'Encrypted artifact integrity mismatch.' }
        if (-not $SkipPayloadHash -and (Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash -cne $s.Sha256) { throw 'Encrypted artifact integrity mismatch.' }
    }
    $null = [DateTime]::Parse($s.RecoveryPointUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    return $s
}

function Send-DBBundle {
    param([Collections.IDictionary] $Configuration, $Runtime, [string] $BundlePath, [switch] $JustCreated)
    $s = Read-DBArtifact $BundlePath $Configuration -SkipPayloadHash:$JustCreated
    $destination = Join-Path (Join-Path $Runtime.Completed $s.Job) (Split-Path -Leaf $BundlePath)
    if (Test-Path -LiteralPath $destination) { throw 'Completed bundle already exists; refusing overwrite.' }
    # Md5 is recorded at creation; bundles from earlier versions compute it here.
    $md5Property = $s.PSObject.Properties['Md5']
    $md5 = if ($null -ne $md5Property) { [string] $md5Property.Value } else { $null }
    $sent = Send-DBBackupFile -RclonePath $Configuration.Tools.Rclone -ConfigPath $Configuration.Storage.ConfigPath -LocalPath (Join-Path $BundlePath $s.FileName) `
        -RemotePath $s.RemotePath -ExpectedSize ([long] $s.SizeBytes) -ExpectedMd5 $md5 -TimeoutSeconds $Configuration.Execution.ToolTimeoutSeconds
    $level = if ($sent.Verification -eq 'size-only') { 'WARN' } else { 'INFO' }
    Write-DBLog $Runtime.LogPath $s.Job "Uploaded $($s.RemotePath); remote verification: $($sent.Verification)." $level
    $s.Transport = 'CONFIRMED'
    Write-DBJson (Join-Path $BundlePath 'state.json') $s
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force
    # Configuration requires the same volume: never split payload and state
    # with a cross-volume copy/delete when confirming transport.
    [IO.Directory]::Move($BundlePath, $destination)
    if (-not $Configuration.Retention.KeepLocalPayload) {
        # State first: a crash after it leaves a harmless extra file, never a
        # bundle whose state claims a payload that is gone.
        $s | Add-Member -NotePropertyName LocalPayload -NotePropertyValue 'REMOVED' -Force
        Write-DBJson (Join-Path $destination 'state.json') $s
        Remove-Item -LiteralPath (Join-Path $destination $s.FileName) -Force -ErrorAction Stop
    }
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
    # A directory job archives its configured source in place under content/
    # instead of staging a full copy in Work.
    $contentPath = $null
    $contentProperty = $Package.PSObject.Properties['ContentPath']
    if ($null -ne $contentProperty -and -not [string]::IsNullOrEmpty([string] $contentProperty.Value)) {
        $contentPath = [IO.Path]::GetFullPath([string] $contentProperty.Value)
        if ($Job.Provider -ne 'Directory' -or $contentPath -ne $Job.SourcePath) { throw 'External package content must be the configured directory source.' }
        if (Test-DBPathWithin $contentPath $Runtime.Work) { throw 'External package content cannot be inside Work.' }
        if ((Get-Item -LiteralPath $contentPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Directory source cannot be a link.' }
        if (@(Get-ChildItem -LiteralPath $source -Force).Count -gt 0) { throw 'A package with external content must have an empty metadata directory.' }
    }
    $files = @()
    $roots = @(@{ Root = $source; Prefix = '' })
    if ($null -ne $contentPath) { $roots += @{ Root = $contentPath; Prefix = 'content/' } }
    foreach ($entry in $roots) {
        foreach ($file in Get-ChildItem -LiteralPath $entry.Root -Recurse -Force -ErrorAction Stop) {
            if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Payload contains a link.' }
            if (-not $file.PSIsContainer) {
                $files += @{ Path = $entry.Prefix + [IO.Path]::GetRelativePath($entry.Root, $file.FullName).Replace('\','/'); SizeBytes = $file.Length; Sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash }
            }
        }
    }
    $versions = @{}
    $toolKeys = @('SevenZip', 'Age', 'Rclone')
    if ($Job.Provider -eq 'MySQL') { $toolKeys += @('MySql', 'MySqlDump') }
    if ($Job.Provider -eq 'SQLAnywhere') { $toolKeys += @('DbBackup') }
    foreach ($key in $toolKeys) {
        $tool = Get-Item -LiteralPath $Configuration.Tools[$key] -ErrorAction Stop
        $versions[$key] = @{ FileVersion = $tool.VersionInfo.FileVersion; Sha256 = (Get-FileHash -LiteralPath $tool.FullName -Algorithm SHA256).Hash }
    }
    Write-DBJson $manifestPath @{
        SchemaVersion = 1; Producer = 'dbbackup'; ProducerVersion = (Get-DBApplicationVersion); Provider = $Job.Provider; Instance = $Configuration.InstanceName
        Job = $Job.Id; RunId = $Runtime.RunId; Role = $Package.Role; Status = $Result.Status
        StartedAtUtc = $Result.StartedAtUtc.ToString('o'); FinishedAtUtc = $Result.FinishedAtUtc.ToString('o')
        Metadata = $Result.Metadata; Files = $files; Tools = $versions
        Roles = @($Result.Packages.Role)
    }
    $payloadBytes = Get-DBDirectorySize $source
    if ($null -ne $contentPath) { $payloadBytes += Get-DBDirectorySize $contentPath }
    Assert-DBFreeSpace -Path $Runtime.Work -RequiredBytes ([long] ([decimal] $payloadBytes * 1.05 + 1048576)) -ReserveBytes $Configuration.Execution.ReserveBytes
    $archive = Join-Path $Runtime.Work "$base.7z"
    $archiveSettings = @{
        SevenZipPath = $Configuration.Tools.SevenZip; ArchivePath = $archive; CompressionLevel = $Configuration.Archive.CompressionLevel
        CpuLimitPercent = $Configuration.Archive.CpuLimitPercent; TimeoutSeconds = $Configuration.Execution.ToolTimeoutSeconds
    }
    if ($null -ne $contentPath) {
        $null = New-DBArchiveWithContent @archiveSettings -MetadataPath $source -ContentPath $contentPath -ReserveBytes $Configuration.Execution.ReserveBytes
    }
    else {
        $null = New-DBArchive @archiveSettings -SourcePath $source -ContentsOnly
    }
    # The tested archive holds everything: drop the plaintext payload before
    # encrypting so the payload, the .7z and the .age never coexist on disk.
    $sharedSource = @($Result.Packages | Where-Object {
        $other = [IO.Path]::GetFullPath($_.SourcePath)
        $other -ne $source -and ((Test-DBPathWithin $other $source) -or (Test-DBPathWithin $source $other))
    })
    if ($sharedSource.Count -eq 0) { Remove-Item -LiteralPath $source -Recurse -Force -ErrorAction Stop }
    $bundle = Join-Path $Runtime.Staging $base
    Set-DBPrivateDirectory $bundle
    try {
        Assert-DBFreeSpace -Path $Runtime.Staging -RequiredBytes ([long] ([decimal] (Get-Item -LiteralPath $archive).Length * 1.05 + 1048576)) -ReserveBytes $Configuration.Execution.ReserveBytes
        $temp = Join-Path $bundle 'payload.tmp'
        Protect-DBArchive -AgePath $Configuration.Tools.Age -InputPath $archive -OutputPath $temp -RecipientsFile $Configuration.Encryption.RecipientsFile -TimeoutSeconds $Configuration.Execution.ToolTimeoutSeconds
        $name = "$base.7z.age"
        $payload = Join-Path $bundle $name
        Move-Item -LiteralPath $temp -Destination $payload -ErrorAction Stop
        $remote = '{0}/{1}/{2}/{3}/{4}' -f $Configuration.Storage.RemoteRoot.TrimEnd('/'), $Configuration.InstanceName, $Job.Id, $Result.StartedAtUtc.ToString('yyyy/MM/dd'), $name
        # One read yields size, SHA-256 (local integrity) and MD5 (remote check).
        $digest = Get-DBFileDigest -Path $payload
        Write-DBJson (Join-Path $bundle 'state.json') @{
            SchemaVersion = 1; Instance = $Configuration.InstanceName; Job = $Job.Id; RunId = $Runtime.RunId
            Role = $Package.Role; LocalStatus = $Result.Status; RecoveryPointUtc = $Result.StartedAtUtc.ToString('o')
            FileName = $name; SizeBytes = $digest.Length; Sha256 = $digest.Sha256; Md5 = $digest.Md5
            RemotePath = $remote; Transport = 'PENDING'
        }
        $pendingParent = Join-Path $Runtime.Pending $Job.Id
        $null = New-Item -ItemType Directory -Path $pendingParent -Force
        $pending = Join-Path $pendingParent $base
        [IO.Directory]::Move($bundle, $pending)
        Send-DBBundle -Configuration $Configuration -Runtime $Runtime -BundlePath $pending -JustCreated
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
    <#
    A bundle or log that cannot be read is reported and skipped; it never stops
    retention of the remaining items. Any skipped item fails maintenance.
    #>
    param([Collections.IDictionary] $Configuration, $Runtime)
    $problems = 0
    foreach ($job in $Configuration.Jobs) {
        $parent = Join-Path $Runtime.Completed $job.Id
        if (-not (Test-Path -LiteralPath $parent)) { continue }
        foreach ($bundle in @(Get-ChildItem -LiteralPath $parent -Directory)) {
            try {
                # Deciding expiry needs state and ownership, not a full re-hash
                # of every retained payload on every run.
                $state = Read-DBArtifact $bundle.FullName $Configuration -SkipPayloadHash
                if ($state.Job -cne $job.Id -or $state.Transport -cne 'CONFIRMED') { throw 'Completed state mismatch.' }
                if (([DateTime] $state.RecoveryPointUtc).ToUniversalTime() -lt [DateTime]::UtcNow.AddDays(-[int] $Configuration.Retention.CompletedDays)) {
                    Remove-Item -LiteralPath $bundle.FullName -Recurse -Force -ErrorAction Stop
                }
            }
            catch {
                $problems++
                Write-DBLog $Runtime.LogPath 'Retention' "Skipped completed bundle $($bundle.FullName): $($_.Exception.Message)" 'ERROR'
            }
        }
    }
    foreach ($log in @(Get-ChildItem -LiteralPath $Configuration.Paths.LogRoot -File -Filter 'DBBackupLog_*.log')) {
        if ($log.FullName -eq $Runtime.LogPath -or $log.Name -notmatch '^DBBackupLog_(\d{8}T\d{6}Z)_[a-f0-9]{32}\.log$') { continue }
        try {
            $date = [DateTime]::ParseExact($Matches[1], 'yyyyMMddTHHmmssZ', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime()
            if ($date -lt [DateTime]::UtcNow.AddDays(-[int] $Configuration.Retention.LogDays)) { Remove-Item -LiteralPath $log.FullName -Force -ErrorAction Stop }
        }
        catch {
            $problems++
            Write-DBLog $Runtime.LogPath 'Retention' "Skipped log $($log.FullName): $($_.Exception.Message)" 'ERROR'
        }
    }
    if ($problems -gt 0) { throw "Retention skipped $problems item(s); the remaining items were processed." }
}

function Get-DBPendingSummary {
    <# Count and bytes of encrypted bundles still waiting for upload for one job. #>
    param($Runtime, [string] $Job)
    $parent = Join-Path $Runtime.Pending $Job
    $count = 0
    [long] $bytes = 0
    if (Test-Path -LiteralPath $parent) {
        foreach ($bundle in @(Get-ChildItem -LiteralPath $parent -Directory)) {
            $count++
            foreach ($file in @(Get-ChildItem -LiteralPath $bundle.FullName -File -Filter '*.age')) { $bytes += $file.Length }
        }
    }
    [pscustomobject]@{ Count = $count; Bytes = $bytes }
}

function Publish-DBLog {
    param([Collections.IDictionary] $Configuration, $Runtime, [double] $TimeoutSeconds = 900)
    $remote = '{0}/{1}/Logs/{2}/{3}' -f $Configuration.Storage.RemoteRoot.TrimEnd('/'), $Configuration.InstanceName, [DateTime]::UtcNow.ToString('yyyy/MM/dd'), [IO.Path]::GetFileName($Runtime.LogPath)
    $null = Send-DBBackupFile -RclonePath $Configuration.Tools.Rclone -ConfigPath $Configuration.Storage.ConfigPath -LocalPath $Runtime.LogPath -RemotePath $remote -TimeoutSeconds $TimeoutSeconds
}

Export-ModuleMember -Function Assert-DBBackupDependency, Publish-DBPackage, Invoke-DBPendingRetry, Remove-DBExpired, Get-DBPendingSummary, Publish-DBLog, Read-DBArtifact, Test-DBLocalPayloadRemoved
