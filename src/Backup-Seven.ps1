#requires -Version 7.0

[CmdletBinding()]
param(
    [ValidateSet('Database', 'Fiscal', 'Full')]
    [string] $Mode = 'Full',

    [string] $ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$moduleRoot = Join-Path $PSScriptRoot 'Modules'
Import-Module (Join-Path $moduleRoot 'Logging.psm1') -Force
Import-Module (Join-Path $moduleRoot 'Database.psm1') -Force
Import-Module (Join-Path $moduleRoot 'Fiscal.psm1') -Force
Import-Module (Join-Path $moduleRoot 'Archive.psm1') -Force
Import-Module (Join-Path $moduleRoot 'Storage.psm1') -Force

function Get-ApplicationVersion {
    $candidates = @(
        (Join-Path $PSScriptRoot 'VERSION')
        (Join-Path (Split-Path -Parent $PSScriptRoot) 'VERSION')
    )

    $versionPath = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($versionPath)) {
        throw 'VERSION file was not found.'
    }

    $version = (Get-Content -LiteralPath $versionPath -Raw).Trim()
    if ($version -notmatch '^\d+\.\d+\.\d+$') {
        throw "VERSION must use X.Y.Z format: $version"
    }

    return $version
}

function Assert-ConfigurationSection {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Configuration,

        [Parameter(Mandatory)]
        [string] $Name
    )

    if (-not $Configuration.Contains($Name) -or $Configuration[$Name] -isnot [System.Collections.IDictionary]) {
        throw "Configuration section '$Name' is required."
    }
}

function Assert-ConfigurationValue {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Section,

        [Parameter(Mandatory)]
        [string] $Key,

        [Parameter(Mandatory)]
        [string] $DisplayName
    )

    if (-not $Section.Contains($Key) -or [string]::IsNullOrWhiteSpace([string] $Section[$Key])) {
        throw "Configuration value '$DisplayName' is required."
    }
}

function Read-BackupConfiguration {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string[]] $BackupTypes
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration file was not found: $Path"
    }

    $configuration = Import-PowerShellDataFile -LiteralPath $Path
    if ($configuration -isnot [System.Collections.IDictionary]) {
        throw 'Configuration root must be a hashtable.'
    }

    foreach ($section in @('Tools', 'Storage', 'Archive', 'Paths', 'Retention')) {
        Assert-ConfigurationSection -Configuration $configuration -Name $section
    }

    Assert-ConfigurationValue -Section $configuration -Key 'InstanceName' -DisplayName 'InstanceName'
    if ([string] $configuration.InstanceName -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') {
        throw 'InstanceName may contain only letters, numbers, underscore, and hyphen.'
    }

    Assert-ConfigurationValue -Section $configuration.Tools -Key 'SevenZip' -DisplayName 'Tools.SevenZip'
    Assert-ConfigurationValue -Section $configuration.Tools -Key 'Rclone' -DisplayName 'Tools.Rclone'
    Assert-ConfigurationValue -Section $configuration.Storage -Key 'ConfigPath' -DisplayName 'Storage.ConfigPath'
    Assert-ConfigurationValue -Section $configuration.Storage -Key 'RemoteRoot' -DisplayName 'Storage.RemoteRoot'
    Assert-ConfigurationValue -Section $configuration.Archive -Key 'CompressionLevel' -DisplayName 'Archive.CompressionLevel'
    Assert-ConfigurationValue -Section $configuration.Paths -Key 'RuntimeRoot' -DisplayName 'Paths.RuntimeRoot'
    Assert-ConfigurationValue -Section $configuration.Retention -Key 'CompletedDays' -DisplayName 'Retention.CompletedDays'
    Assert-ConfigurationValue -Section $configuration.Retention -Key 'LogDays' -DisplayName 'Retention.LogDays'

    if ([string] $configuration.Storage.RemoteRoot -notmatch '^[^:]+:.+') {
        throw 'Storage.RemoteRoot must use rclone remote:path syntax.'
    }

    if (-not [System.IO.Path]::IsPathFullyQualified([string] $configuration.Paths.RuntimeRoot)) {
        throw 'Paths.RuntimeRoot must be an absolute path.'
    }

    $compressionLevel = [int] $configuration.Archive.CompressionLevel
    if ($compressionLevel -lt 0 -or $compressionLevel -gt 9) {
        throw 'Archive.CompressionLevel must be between 0 and 9.'
    }

    if ([int] $configuration.Retention.CompletedDays -lt 1 -or [int] $configuration.Retention.LogDays -lt 1) {
        throw 'Retention values must be one or greater.'
    }

    if ('Database' -in $BackupTypes) {
        Assert-ConfigurationSection -Configuration $configuration -Name 'Database'
        Assert-ConfigurationValue -Section $configuration.Tools -Key 'MySqlDump' -DisplayName 'Tools.MySqlDump'
        Assert-ConfigurationValue -Section $configuration.Database -Key 'Name' -DisplayName 'Database.Name'
        Assert-ConfigurationValue -Section $configuration.Database -Key 'DefaultsExtraFile' -DisplayName 'Database.DefaultsExtraFile'
    }

    if ('Fiscal' -in $BackupTypes) {
        Assert-ConfigurationSection -Configuration $configuration -Name 'Fiscal'
        Assert-ConfigurationValue -Section $configuration.Fiscal -Key 'SourcePath' -DisplayName 'Fiscal.SourcePath'
    }

    return $configuration
}

function Get-BackupType {
    param([Parameter(Mandatory)][string] $RequestedMode)

    if ($RequestedMode -eq 'Full') {
        return @('Database', 'Fiscal')
    }

    return @($RequestedMode)
}

function New-RuntimeLayout {
    param(
        [Parameter(Mandatory)][string] $RuntimeRoot,
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string[]] $BackupTypes
    )

    $layout = @{
        Root       = $RuntimeRoot
        Pending    = Join-Path $RuntimeRoot 'Pending'
        Completed = Join-Path $RuntimeRoot 'Completed'
        WorkRoot = Join-Path $RuntimeRoot 'Work'
        Work      = Join-Path (Join-Path $RuntimeRoot 'Work') $RunId
        Logs      = Join-Path $RuntimeRoot 'Logs'
        Lock      = Join-Path $RuntimeRoot 'BackupSeven.lock'
    }

    foreach ($path in @($layout.Root, $layout.Pending, $layout.Completed, $layout.WorkRoot, $layout.Logs)) {
        $null = New-Item -ItemType Directory -Path $path -Force
    }

    foreach ($backupType in $BackupTypes) {
        $null = New-Item -ItemType Directory -Path (Join-Path $layout.Pending $backupType) -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $layout.Completed $backupType) -Force
    }

    return $layout
}

function Assert-LocalDependency {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Configuration,
        [Parameter(Mandatory)][string[]] $BackupTypes
    )

    foreach ($path in @($Configuration.Tools.SevenZip, $Configuration.Tools.Rclone, $Configuration.Storage.ConfigPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Required file was not found: $path"
        }
    }

    if ('Database' -in $BackupTypes) {
        foreach ($path in @($Configuration.Tools.MySqlDump, $Configuration.Database.DefaultsExtraFile)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Required database file was not found: $path"
            }
        }
    }

    if ('Fiscal' -in $BackupTypes -and -not (Test-Path -LiteralPath $Configuration.Fiscal.SourcePath -PathType Container)) {
        throw "Fiscal source directory was not found: $($Configuration.Fiscal.SourcePath)"
    }
}

function New-ArtifactInfo {
    param(
        [Parameter(Mandatory)][string] $InstanceName,
        [Parameter(Mandatory)][string] $BackupType,
        [Parameter(Mandatory)][string] $RunId
    )

    $timestamp = [DateTime]::UtcNow
    $shortRunId = $RunId.Substring(0, 8)
    $fileName = 'BackupSeven_{0}_{1}_{2}_{3}.7z' -f `
        $InstanceName,
        $BackupType,
        $timestamp.ToString('yyyyMMddTHHmmssZ'),
        $shortRunId

    [pscustomobject]@{
        FileName = $fileName
        Year     = $timestamp.ToString('yyyy')
        Month    = $timestamp.ToString('MM')
    }
}

function Get-ArtifactDateInfo {
    param([Parameter(Mandatory)][string] $FileName)

    if ($FileName -notmatch '_((?<date>\d{8})T(?<time>\d{6})Z)_[A-Fa-f0-9]{8}\.7z$') {
        throw "Backup file name does not follow the artifact contract: $FileName"
    }

    [pscustomobject]@{
        Timestamp = [DateTime]::ParseExact(
            "$($Matches.date)T$($Matches.time)Z",
            'yyyyMMddTHHmmssZ',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
        )
        Year  = $Matches.date.Substring(0, 4)
        Month = $Matches.date.Substring(4, 2)
    }
}

function Get-RemoteArchivePath {
    param(
        [Parameter(Mandatory)][string] $RemoteRoot,
        [Parameter(Mandatory)][string] $InstanceName,
        [Parameter(Mandatory)][string] $BackupType,
        [Parameter(Mandatory)][string] $FileName
    )

    $dateParts = Get-ArtifactDateInfo -FileName $FileName
    return '{0}/{1}/{2}/{3}/{4}/{5}' -f `
        $RemoteRoot.TrimEnd('/'),
        $InstanceName,
        $BackupType,
        $dateParts.Year,
        $dateParts.Month,
        $FileName
}

function Publish-BackupArchive {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo] $Archive,
        [Parameter(Mandatory)][string] $BackupType,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Layout
    )

    $dateParts = Get-ArtifactDateInfo -FileName $Archive.Name
    $remotePath = Get-RemoteArchivePath `
        -RemoteRoot $Configuration.Storage.RemoteRoot `
        -InstanceName $Configuration.InstanceName `
        -BackupType $BackupType `
        -FileName $Archive.Name

    Write-BackupLog -Level INFO -Stage "$BackupType/Upload" -Message "Uploading '$($Archive.FullName)' to '$remotePath'."
    $null = Send-SevenBackupFile `
        -RclonePath $Configuration.Tools.Rclone `
        -ConfigPath $Configuration.Storage.ConfigPath `
        -LocalPath $Archive.FullName `
        -RemotePath $remotePath

    $completedDirectory = Join-Path (Join-Path (Join-Path $Layout.Completed $BackupType) $dateParts.Year) $dateParts.Month
    $null = New-Item -ItemType Directory -Path $completedDirectory -Force
    $completedPath = Join-Path $completedDirectory $Archive.Name
    Move-Item -LiteralPath $Archive.FullName -Destination $completedPath -ErrorAction Stop
    Write-BackupLog -Level INFO -Stage "$BackupType/Upload" -Message "Upload validated; archive moved to '$completedPath'."
}

function Invoke-PendingRetry {
    param(
        [Parameter(Mandatory)][string] $BackupType,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Layout
    )

    $succeeded = $true
    $pendingRoot = Join-Path $Layout.Pending $BackupType
    $pendingFiles = @(Get-ChildItem -LiteralPath $pendingRoot -Filter '*.7z' -File -Recurse | Sort-Object FullName)

    foreach ($pendingFile in $pendingFiles) {
        try {
            Write-BackupLog -Level INFO -Stage "$BackupType/Retry" -Message "Retrying pending archive '$($pendingFile.FullName)'."
            Publish-BackupArchive -Archive $pendingFile -BackupType $BackupType -Configuration $Configuration -Layout $Layout
        }
        catch {
            $succeeded = $false
            Write-BackupLog -Level ERROR -Stage "$BackupType/Retry" -Message $_.Exception.Message
        }
    }

    return $succeeded
}

function Invoke-DatabaseBackup {
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Layout
    )

    $artifact = New-ArtifactInfo -InstanceName $Configuration.InstanceName -BackupType Database -RunId $RunId
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($artifact.FileName)
    $dumpPath = Join-Path $Layout.Work "$baseName.sql"
    $workArchivePath = Join-Path $Layout.Work $artifact.FileName
    $pendingDirectory = Join-Path (Join-Path (Join-Path $Layout.Pending 'Database') $artifact.Year) $artifact.Month
    $pendingPath = Join-Path $pendingDirectory $artifact.FileName

    try {
        Write-BackupLog -Level INFO -Stage 'Database/Dump' -Message "Creating database dump '$dumpPath'."
        $extraArguments = @()
        if ($Configuration.Database.Contains('ExtraArguments')) {
            $extraArguments = @($Configuration.Database.ExtraArguments)
        }

        $null = New-SevenDatabaseDump `
            -MySqlDumpPath $Configuration.Tools.MySqlDump `
            -DefaultsExtraFile $Configuration.Database.DefaultsExtraFile `
            -DatabaseName $Configuration.Database.Name `
            -OutputPath $dumpPath `
            -ExtraArguments $extraArguments

        Write-BackupLog -Level INFO -Stage 'Database/Archive' -Message "Creating archive '$workArchivePath'."
        $null = New-SevenArchive `
            -SevenZipPath $Configuration.Tools.SevenZip `
            -SourcePath $dumpPath `
            -ArchivePath $workArchivePath `
            -CompressionLevel ([int] $Configuration.Archive.CompressionLevel)

        $null = New-Item -ItemType Directory -Path $pendingDirectory -Force
        Move-Item -LiteralPath $workArchivePath -Destination $pendingPath -ErrorAction Stop
    }
    finally {
        if (Test-Path -LiteralPath $dumpPath -PathType Leaf) {
            Remove-Item -LiteralPath $dumpPath -Force -ErrorAction Stop
        }
    }

    Publish-BackupArchive `
        -Archive (Get-Item -LiteralPath $pendingPath) `
        -BackupType Database `
        -Configuration $Configuration `
        -Layout $Layout
}

function Invoke-FiscalBackup {
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Layout
    )

    $artifact = New-ArtifactInfo -InstanceName $Configuration.InstanceName -BackupType Fiscal -RunId $RunId
    $workArchivePath = Join-Path $Layout.Work $artifact.FileName
    $pendingDirectory = Join-Path (Join-Path (Join-Path $Layout.Pending 'Fiscal') $artifact.Year) $artifact.Month
    $pendingPath = Join-Path $pendingDirectory $artifact.FileName

    Write-BackupLog -Level INFO -Stage 'Fiscal/Archive' -Message "Creating archive '$workArchivePath'."
    $null = New-SevenFiscalArchive `
        -SevenZipPath $Configuration.Tools.SevenZip `
        -SourcePath $Configuration.Fiscal.SourcePath `
        -ArchivePath $workArchivePath `
        -CompressionLevel ([int] $Configuration.Archive.CompressionLevel)

    $null = New-Item -ItemType Directory -Path $pendingDirectory -Force
    Move-Item -LiteralPath $workArchivePath -Destination $pendingPath -ErrorAction Stop
    Publish-BackupArchive `
        -Archive (Get-Item -LiteralPath $pendingPath) `
        -BackupType Fiscal `
        -Configuration $Configuration `
        -Layout $Layout
}

function Remove-ExpiredLocalFile {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Layout
    )

    $succeeded = $true
    $backupCutoff = [DateTime]::UtcNow.AddDays(-[int] $Configuration.Retention.CompletedDays)

    foreach ($backupType in @('Database', 'Fiscal')) {
        $typeRoot = Join-Path $Layout.Completed $backupType
        if (-not (Test-Path -LiteralPath $typeRoot -PathType Container)) {
            continue
        }

        foreach ($archive in Get-ChildItem -LiteralPath $typeRoot -Filter '*.7z' -File -Recurse) {
            try {
                $dateParts = Get-ArtifactDateInfo -FileName $archive.Name
                if ($dateParts.Timestamp -lt $backupCutoff) {
                    Remove-Item -LiteralPath $archive.FullName -Force -ErrorAction Stop
                    Write-BackupLog -Level INFO -Stage 'Retention/Backup' -Message "Removed expired completed archive '$($archive.FullName)'."
                }
            }
            catch {
                $succeeded = $false
                Write-BackupLog -Level WARN -Stage 'Retention/Backup' -Message $_.Exception.Message
            }
        }
    }

    $logCutoff = [DateTime]::UtcNow.AddDays(-[int] $Configuration.Retention.LogDays)
    $currentLogPath = Get-BackupLogPath
    foreach ($logFile in Get-ChildItem -LiteralPath $Layout.Logs -Filter '*.log' -File -Recurse) {
        if ($logFile.FullName -eq $currentLogPath -or $logFile.LastWriteTimeUtc -ge $logCutoff) {
            continue
        }

        try {
            Remove-Item -LiteralPath $logFile.FullName -Force -ErrorAction Stop
        }
        catch {
            $succeeded = $false
            Write-BackupLog -Level WARN -Stage 'Retention/Log' -Message $_.Exception.Message
        }
    }

    return $succeeded
}

function Remove-RunWorkDirectory {
    param(
        [Parameter(Mandatory)][string] $WorkPath,
        [Parameter(Mandatory)][string] $WorkRoot
    )

    $resolvedWorkPath = [System.IO.Path]::GetFullPath($WorkPath)
    $resolvedWorkRoot = [System.IO.Path]::GetFullPath($WorkRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedWorkPath.StartsWith($resolvedWorkRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove work directory outside '$resolvedWorkRoot'."
    }

    if (Test-Path -LiteralPath $resolvedWorkPath -PathType Container) {
        Remove-Item -LiteralPath $resolvedWorkPath -Recurse -Force -ErrorAction Stop
    }
}

function Invoke-BackupSeven {
    param(
        [Parameter(Mandatory)][string] $RequestedMode,
        [string] $RequestedConfigPath
    )

    $runId = [guid]::NewGuid().ToString('N')
    $backupTypes = Get-BackupType -RequestedMode $RequestedMode
    $lockStream = $null
    $layout = $null
    $logInitialized = $false

    try {
        if ([string]::IsNullOrWhiteSpace($RequestedConfigPath)) {
            $RequestedConfigPath = Join-Path $PSScriptRoot 'config.psd1'
        }

        $version = Get-ApplicationVersion
        $configuration = Read-BackupConfiguration -Path $RequestedConfigPath -BackupTypes $backupTypes
        $layout = New-RuntimeLayout -RuntimeRoot $configuration.Paths.RuntimeRoot -RunId $runId -BackupTypes $backupTypes
        $null = Initialize-BackupLog -LogRoot $layout.Logs -RunId $runId -Mode $RequestedMode -Version $version
        $logInitialized = $true

        try {
            $lockStream = [System.IO.File]::Open(
                $layout.Lock,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
        }
        catch [System.IO.IOException] {
            Write-BackupLog -Level ERROR -Stage 'Startup/Lock' -Message 'Another BackupSeven execution is already active.'
            return 3
        }

        $null = New-Item -ItemType Directory -Path $layout.Work -Force
        Assert-LocalDependency -Configuration $configuration -BackupTypes $backupTypes
        $null = Test-SevenStorageConfiguration `
            -RclonePath $configuration.Tools.Rclone `
            -ConfigPath $configuration.Storage.ConfigPath `
            -RemoteRoot $configuration.Storage.RemoteRoot

        $operationSucceeded = $true
        foreach ($backupType in $backupTypes) {
            if (-not (Invoke-PendingRetry -BackupType $backupType -Configuration $configuration -Layout $layout)) {
                $operationSucceeded = $false
            }
        }

        foreach ($backupType in $backupTypes) {
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                if ($backupType -eq 'Database') {
                    Invoke-DatabaseBackup -RunId $runId -Configuration $configuration -Layout $layout
                }
                else {
                    Invoke-FiscalBackup -RunId $runId -Configuration $configuration -Layout $layout
                }

                Write-BackupLog -Level INFO -Stage "$backupType/Complete" -Message "Pipeline completed in $([math]::Round($stopwatch.Elapsed.TotalSeconds, 1)) seconds."
            }
            catch {
                $operationSucceeded = $false
                Write-BackupLog -Level ERROR -Stage "$backupType/Failed" -Message $_.Exception.Message
            }
            finally {
                $stopwatch.Stop()
            }
        }

        $maintenanceSucceeded = $true
        try {
            Remove-RunWorkDirectory -WorkPath $layout.Work -WorkRoot $layout.WorkRoot
        }
        catch {
            $maintenanceSucceeded = $false
            Write-BackupLog -Level ERROR -Stage 'Cleanup/Work' -Message $_.Exception.Message
        }

        if (-not (Remove-ExpiredLocalFile -Configuration $configuration -Layout $layout)) {
            $maintenanceSucceeded = $false
        }

        if (-not $operationSucceeded) {
            Write-BackupLog -Level ERROR -Stage 'Complete' -Message 'Execution completed with backup or upload failures.'
            return 1
        }

        if (-not $maintenanceSucceeded) {
            Write-BackupLog -Level ERROR -Stage 'Complete' -Message 'Backups completed, but cleanup or retention failed.'
            return 4
        }

        Write-BackupLog -Level INFO -Stage 'Complete' -Message 'Execution completed successfully.'
        return 0
    }
    catch {
        if ($logInitialized) {
            Write-BackupLog -Level ERROR -Stage 'Startup' -Message $_.Exception.Message
        }
        else {
            Write-Error $_.Exception.Message -ErrorAction Continue
        }

        return 2
    }
    finally {
        if ($null -ne $lockStream) {
            $lockStream.Dispose()
        }

        if ($null -ne $layout -and (Test-Path -LiteralPath $layout.Work -PathType Container)) {
            try {
                Remove-RunWorkDirectory -WorkPath $layout.Work -WorkRoot $layout.WorkRoot
            }
            catch {
                if ($logInitialized) {
                    Write-BackupLog -Level ERROR -Stage 'Cleanup/Work' -Message $_.Exception.Message
                }
            }
        }
    }
}

exit (Invoke-BackupSeven -RequestedMode $Mode -RequestedConfigPath $ConfigPath)
