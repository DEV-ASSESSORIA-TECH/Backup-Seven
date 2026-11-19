Set-StrictMode -Version Latest
foreach ($module in @('Archive', 'Storage', 'Encryption', 'Runtime', 'Configuration', 'Capacity', 'Observation')) { Import-Module (Join-Path $PSScriptRoot "$module.psm1") }

function Assert-DBBackupDependency {
    param([Collections.IDictionary] $Configuration, [object[]] $Jobs)
    $paths = @($Configuration.Tools.SevenZip, $Configuration.Tools.Age, $Configuration.Tools.Rclone, $Configuration.Storage.ConfigPath)
    foreach ($j in $Jobs) {
        switch ($j.Provider) {
            MySQL { $paths += @($Configuration.Tools.MySql, $Configuration.Tools.MySqlDump, $j.CredentialFile) }
            SQLAnywhere { $paths += @($Configuration.Tools.DbBackup, $j.CredentialFile) }
            Directory { if (-not (Test-Path -LiteralPath $j.SourcePath -PathType Container)) { throw "Job $($j.Id): directory source is missing: $($j.SourcePath)" } }
        }
    }
    foreach ($path in $paths) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required dependency is missing: $path" } }
    $null = Read-DBRecipient $Configuration.Encryption.RecipientsFile
    # Every rclone remote named by the selected jobs must exist in rclone.conf.
    foreach ($root in @($Jobs | ForEach-Object RemoteRoot | Select-Object -Unique)) {
        $null = Test-DBStorageConfiguration -RclonePath $Configuration.Tools.Rclone -ConfigPath $Configuration.Storage.ConfigPath -RemoteRoot $root -TimeoutSeconds $Configuration.Execution.ToolTimeoutSeconds
    }
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
    if ($s.FileName -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*\.7z\.age$' -or [IO.Path]::GetFileName($s.FileName) -cne $s.FileName) { throw 'Unsafe artifact file name.' }
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
    Write-DBLog $Runtime.LogPath $s.Job "Step 4/4: uploading $([Math]::Round([long] $s.SizeBytes / 1MB)) MB to $($s.RemotePath)."
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

function Get-DBArtifactBaseName {
    <#
    Operator-readable name, local time first:
    2026-11-18_09-54-17_<instance>_<job>[_GERAL|_GRANULAR]. FULL has no suffix.
    The run ID stays in state.json and in the manifest. A name already used in
    Staging, Pending or Completed gets -2, -3, ...
    #>
    param([Collections.IDictionary] $Configuration, $Runtime, $Job, [DateTime] $StartedAtUtc, [string] $Role)
    Assert-DBIdentifier $Role
    $suffix = switch ($Role) { 'FULL' { '' } 'GENERAL' { '_GERAL' } default { "_$Role" } }
    $stamp = $StartedAtUtc.ToLocalTime().ToString('yyyy-MM-dd_HH-mm-ss', [Globalization.CultureInfo]::InvariantCulture)
    $candidate = "${stamp}_$($Configuration.InstanceName)_$($Job.Id)$suffix"
    $name = $candidate
    for ($n = 2; $n -lt 1000; $n++) {
        $taken = @(
            (Join-Path $Runtime.Staging $name)
            (Join-Path (Join-Path $Runtime.Pending $Job.Id) $name)
            (Join-Path (Join-Path $Runtime.Completed $Job.Id) $name)
        ) | Where-Object { Test-Path -LiteralPath $_ }
        if (@($taken).Count -eq 0) { return $name }
        $name = "$candidate-$n"
    }
    throw 'Could not allocate a unique artifact name.'
}

function Publish-DBPackage {
    param([Collections.IDictionary] $Configuration, $Runtime, $Job, $Result, $Package)
    $base = Get-DBArtifactBaseName -Configuration $Configuration -Runtime $Runtime -Job $Job -StartedAtUtc $Result.StartedAtUtc -Role $Package.Role
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
    Write-DBLog $Runtime.LogPath $Job.Id "Step 2/4: compressing $([Math]::Round($payloadBytes / 1MB)) MB into $base.7z (7-Zip, level $($Configuration.Archive.CompressionLevel)) and testing the archive."
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
        Write-DBLog $Runtime.LogPath $Job.Id "Step 3/4: encrypting $([Math]::Round((Get-Item -LiteralPath $archive).Length / 1MB)) MB with age."
        Protect-DBArchive -AgePath $Configuration.Tools.Age -InputPath $archive -OutputPath $temp -RecipientsFile $Configuration.Encryption.RecipientsFile -TimeoutSeconds $Configuration.Execution.ToolTimeoutSeconds
        $name = "$base.7z.age"
        $payload = Join-Path $bundle $name
        Move-Item -LiteralPath $temp -Destination $payload -ErrorAction Stop
        # RemoteRoot is the instance's complete destination (bucket/prefix).
        # Job destination (<RemoteRoot>/<job>), then the local date of the file name.
        # Incrementals go to <RemoteRoot>/<job>/incremental/ for a lifecycle rule of their own.
        $destination = if ($Package.Role -ceq 'INCREMENTAL') { $Job.IncrementalDestination } else { $Job.Destination }
        $remote = '{0}/{1}/{2}' -f $destination, $Result.StartedAtUtc.ToLocalTime().ToString('yyyy/MM/dd', [Globalization.CultureInfo]::InvariantCulture), $name
        # One read yields size, SHA-256 (local integrity) and MD5 (remote check).
        $digest = Get-DBFileDigest -Path $payload
        $state = @{
            SchemaVersion = 1; Instance = $Configuration.InstanceName; Job = $Job.Id; RunId = $Runtime.RunId
            Role = $Package.Role; LocalStatus = $Result.Status; RecoveryPointUtc = $Result.StartedAtUtc.ToString('o')
            FileName = $name; SizeBytes = $digest.Length; Sha256 = $digest.Sha256; Md5 = $digest.Md5
            RemotePath = $remote; Transport = 'PENDING'
        }
        if ($Package.Role -ceq 'INCREMENTAL') { $state.BaseRunId = $Result.Metadata.BaseRunId; $state.BaseRecoveryPointUtc = $Result.Metadata.BaseRecoveryPointUtc }
        Write-DBJson (Join-Path $bundle 'state.json') $state
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
    Bundles older than Retention.CompletedDays are removed. An incremental is
    also removed once its base is older than the previous confirmed full: a
    new full drops the incrementals of the day before and keeps those of the
    last day. A failed full moves nothing, so nothing new is removed.
    #>
    param([Collections.IDictionary] $Configuration, $Runtime)
    $problems = 0
    foreach ($job in $Configuration.Jobs) {
        $parent = Join-Path $Runtime.Completed $job.Id
        if (-not (Test-Path -LiteralPath $parent)) { continue }
        $entries = @()
        foreach ($bundle in @(Get-ChildItem -LiteralPath $parent -Directory)) {
            try {
                # Deciding expiry needs state and ownership, not a full re-hash
                # of every retained payload on every run.
                $state = Read-DBArtifact $bundle.FullName $Configuration -SkipPayloadHash
                if ($state.Job -cne $job.Id -or $state.Transport -cne 'CONFIRMED') { throw 'Completed state mismatch.' }
                $entries += [pscustomobject]@{ Path = $bundle.FullName; State = $state; Time = ([DateTime] $state.RecoveryPointUtc).ToUniversalTime() }
            }
            catch {
                $problems++
                Write-DBLog $Runtime.LogPath 'Retention' "Skipped completed bundle $($bundle.FullName): $($_.Exception.Message)" 'ERROR'
            }
        }
        $fulls = @($entries | Where-Object { $_.State.Role -ceq 'FULL' -and $_.State.LocalStatus -ceq 'SUCCESS' } | Sort-Object Time -Descending)
        $threshold = if ($fulls.Count -ge 2) { $fulls[1].Time } else { $null }
        foreach ($entry in $entries) {
            try {
                $expired = $entry.Time -lt [DateTime]::UtcNow.AddDays(-[int] $Configuration.Retention.CompletedDays)
                if (-not $expired -and $null -ne $threshold -and $entry.State.Role -ceq 'INCREMENTAL') {
                    $baseProperty = $entry.State.PSObject.Properties['BaseRecoveryPointUtc']
                    if ($null -ne $baseProperty -and $baseProperty.Value) { $expired = ([DateTime] $baseProperty.Value).ToUniversalTime() -lt $threshold }
                }
                if ($expired) { Remove-Item -LiteralPath $entry.Path -Recurse -Force -ErrorAction Stop }
            }
            catch {
                $problems++
                Write-DBLog $Runtime.LogPath 'Retention' "Skipped completed bundle $($entry.Path): $($_.Exception.Message)" 'ERROR'
            }
        }
    }
    foreach ($log in @(Get-ChildItem -LiteralPath $Configuration.Paths.LogRoot -File -Filter '*.log')) {
        # Only DBBackup run logs (yyyy-MM-dd_HH-mm-ss[-n].log, local time) are aged out.
        if ($log.FullName -eq $Runtime.LogPath -or $log.Name -notmatch '^(\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})(-\d+)?\.log$') { continue }
        try {
            $date = [DateTime]::ParseExact($Matches[1], 'yyyy-MM-dd_HH-mm-ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal).ToUniversalTime()
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
    <#
    The run log goes to <RemoteRoot>/Logs/yyyy/MM/dd/<log>_<instance>.log of
    every distinct RemoteRoot used by the jobs of this run. All destinations
    are attempted; the first failure is rethrown afterwards.
    #>
    param([Collections.IDictionary] $Configuration, $Runtime, [object[]] $Jobs, [double] $TimeoutSeconds = 900)
    $name = '{0}_{1}.log' -f [IO.Path]::GetFileNameWithoutExtension($Runtime.LogPath), $Configuration.InstanceName
    $date = [DateTime]::Now.ToString('yyyy/MM/dd', [Globalization.CultureInfo]::InvariantCulture)
    $failure = $null
    foreach ($root in @($Jobs | ForEach-Object RemoteRoot | Select-Object -Unique)) {
        try { $null = Send-DBBackupFile -RclonePath $Configuration.Tools.Rclone -ConfigPath $Configuration.Storage.ConfigPath -LocalPath $Runtime.LogPath -RemotePath "$root/Logs/$date/$name" -TimeoutSeconds $TimeoutSeconds }
        catch { if ($null -eq $failure) { $failure = $_ } }
    }
    if ($null -ne $failure) { throw $failure }
}

Export-ModuleMember -Function Assert-DBBackupDependency, Publish-DBPackage, Invoke-DBPendingRetry, Remove-DBExpired, Get-DBPendingSummary, Publish-DBLog, Read-DBArtifact, Test-DBLocalPayloadRemoved
