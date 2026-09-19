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
    Assert-ConfigurationValue -Section $configuration.Archive -Key 'CpuLimitPercent' -DisplayName 'Archive.CpuLimitPercent'
    Assert-ConfigurationValue -Section $configuration.Paths -Key 'RuntimeRoot' -DisplayName 'Paths.RuntimeRoot'
    Assert-ConfigurationValue -Section $configuration.Paths -Key 'CompletedRoot' -DisplayName 'Paths.CompletedRoot'
    Assert-ConfigurationValue -Section $configuration.Paths -Key 'LogRoot' -DisplayName 'Paths.LogRoot'
    Assert-ConfigurationValue -Section $configuration.Retention -Key 'CompletedDays' -DisplayName 'Retention.CompletedDays'
    Assert-ConfigurationValue -Section $configuration.Retention -Key 'LogDays' -DisplayName 'Retention.LogDays'

    if ([string] $configuration.Storage.RemoteRoot -notmatch '^[^:]+:.+') {
        throw 'Storage.RemoteRoot must use rclone remote:path syntax.'
    }

    if (-not [System.IO.Path]::IsPathFullyQualified([string] $configuration.Paths.RuntimeRoot)) {
        throw 'Paths.RuntimeRoot must be an absolute path.'
    }

    if (-not [System.IO.Path]::IsPathFullyQualified([string] $configuration.Paths.CompletedRoot)) {
        throw 'Paths.CompletedRoot must be an absolute path.'
    }

    if (-not [System.IO.Path]::IsPathFullyQualified([string] $configuration.Paths.LogRoot)) {
        throw 'Paths.LogRoot must be an absolute path.'
    }

    $compressionLevel = [int] $configuration.Archive.CompressionLevel
    if ($compressionLevel -lt 0 -or $compressionLevel -gt 9) {
        throw 'Archive.CompressionLevel must be between 0 and 9.'
    }

    $cpuLimitPercent = [int] $configuration.Archive.CpuLimitPercent
    if ($cpuLimitPercent -lt 1 -or $cpuLimitPercent -gt 100) {
        throw 'Archive.CpuLimitPercent must be between 1 and 100.'
    }

    if ([int] $configuration.Retention.CompletedDays -lt 1 -or [int] $configuration.Retention.LogDays -lt 1) {
        throw 'Retention values must be one or greater.'
    }

    if ('Database' -in $BackupTypes) {
        Assert-ConfigurationSection -Configuration $configuration -Name 'Database'
        Assert-ConfigurationValue -Section $configuration.Tools -Key 'MySqlDump' -DisplayName 'Tools.MySqlDump'
        Assert-ConfigurationValue -Section $configuration.Tools -Key 'MySql' -DisplayName 'Tools.MySql'
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
        [Parameter(Mandatory)][string] $CompletedRoot,
        [Parameter(Mandatory)][string] $LogRoot,
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string[]] $BackupTypes
    )

    $layout = @{
        Root       = $RuntimeRoot
        Pending    = Join-Path $RuntimeRoot 'Pending'
        Completed = $CompletedRoot
        WorkRoot = Join-Path $RuntimeRoot 'Work'
        Work      = Join-Path (Join-Path $RuntimeRoot 'Work') $RunId
        Logs      = $LogRoot
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
        foreach ($path in @($Configuration.Tools.MySqlDump, $Configuration.Tools.MySql, $Configuration.Database.DefaultsExtraFile)) {
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
    $fileName = 'BackupSeven_{0}_{1}Z_{2}_{3}_{4}.7z' -f `
        $timestamp.ToString('yyyy-MM-dd'),
        $timestamp.ToString('HHmmss'),
        $InstanceName,
        $BackupType,
        $shortRunId

    [pscustomobject]@{
        FileName = $fileName
        Year     = $timestamp.ToString('yyyy')
        Month    = $timestamp.ToString('MM')
        Day      = $timestamp.ToString('dd')
    }
}

function Get-ArtifactDateInfo {
    param([Parameter(Mandatory)][string] $FileName)

    if ($FileName -notmatch '^BackupSeven_(?<date>\d{4}-\d{2}-\d{2})_(?<time>\d{6})Z_[A-Za-z0-9][A-Za-z0-9_-]*_(Database|Fiscal)_[A-Fa-f0-9]{8}(?:_(?:DEGRADED|GRANULAR_DEGRADED))?\.7z$') {
        throw "Backup file name does not follow the artifact contract: $FileName"
    }

    [pscustomobject]@{
        Timestamp = [DateTime]::ParseExact(
            "$($Matches.date)_$($Matches.time)Z",
            'yyyy-MM-dd_HHmmssZ',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
        )
        Year  = $Matches.date.Substring(0, 4)
        Month = $Matches.date.Substring(5, 2)
        Day   = $Matches.date.Substring(8, 2)
    }
}

function Get-LogDateInfo {
    param([Parameter(Mandatory)][string] $FileName)

    if ($FileName -notmatch '^BackupSevenLog_(?<date>\d{4}-\d{2}-\d{2})_(?<time>\d{6})Z_[A-Za-z0-9][A-Za-z0-9_-]*_(Database|Fiscal|Full)_[A-Fa-f0-9]{8}\.log$') {
        throw "Log file name does not follow the artifact contract: $FileName"
    }

    [pscustomobject]@{
        Timestamp = [DateTime]::ParseExact(
            "$($Matches.date)_$($Matches.time)Z",
            'yyyy-MM-dd_HHmmssZ',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
        )
        Year  = $Matches.date.Substring(0, 4)
        Month = $Matches.date.Substring(5, 2)
        Day   = $Matches.date.Substring(8, 2)
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
    return '{0}/{1}/{2}/{3}/{4}/{5}/{6}' -f `
        $RemoteRoot.TrimEnd('/'),
        $InstanceName,
        $BackupType,
        $dateParts.Year,
        $dateParts.Month,
        $dateParts.Day,
        $FileName
}

function Publish-ExecutionLog {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Configuration
    )

    $logPath = Get-BackupLogPath
    $logFile = Get-Item -LiteralPath $logPath -ErrorAction Stop
    $dateParts = Get-LogDateInfo -FileName $logFile.Name
    $remotePath = '{0}/{1}/Logs/{2}/{3}/{4}/{5}' -f `
        $Configuration.Storage.RemoteRoot.TrimEnd('/'),
        $Configuration.InstanceName,
        $dateParts.Year,
        $dateParts.Month,
        $dateParts.Day,
        $logFile.Name

    Write-BackupLog -Level INFO -Stage 'Log/Upload' -Message "Publishing final execution log to '$remotePath'."
    $null = Send-SevenBackupFile `
        -RclonePath $Configuration.Tools.Rclone `
        -ConfigPath $Configuration.Storage.ConfigPath `
        -LocalPath $logFile.FullName `
        -RemotePath $remotePath
}

function Publish-BackupArchive {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo] $Archive,
        [Parameter(Mandatory)][string] $BackupType,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Layout
    )

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

    $completedDirectory = Join-Path $Layout.Completed $BackupType
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

function ConvertTo-ManifestError {
    param([AllowNull()][string] $Message)

    if ([string]::IsNullOrWhiteSpace($Message)) { return '' }
    $sanitized = $Message -replace '(?i)(password\s*[=:]\s*)\S+', '$1[REDACTED]'
    return ($sanitized -replace '[\r\n]+', ' ').Trim()
}

function Write-DatabaseManifest {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Manifest,
        [Parameter(Mandatory)][string[]] $Directories
    )

    $json = $Manifest | ConvertTo-Json -Depth 12
    foreach ($directory in $Directories) {
        $null = New-Item -ItemType Directory -Path $directory -Force
        Set-Content -LiteralPath (Join-Path $directory 'manifest.json') -Value $json -Encoding utf8
    }
}

function Publish-DatabaseWorkArchive {
    param(
        [Parameter(Mandatory)][string] $WorkArchivePath,
        [Parameter(Mandatory)][pscustomobject] $Artifact,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Layout
    )

    $pendingDirectory = Join-Path (Join-Path (Join-Path $Layout.Pending 'Database') $Artifact.Year) $Artifact.Month
    $null = New-Item -ItemType Directory -Path $pendingDirectory -Force
    $pendingPath = Join-Path $pendingDirectory ([System.IO.Path]::GetFileName($WorkArchivePath))
    Move-Item -LiteralPath $WorkArchivePath -Destination $pendingPath -ErrorAction Stop
    Publish-BackupArchive -Archive (Get-Item -LiteralPath $pendingPath) -BackupType Database -Configuration $Configuration -Layout $Layout
}

function Invoke-DegradedDatabaseBackup {
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][pscustomobject] $Artifact,
        [Parameter(Mandatory)][datetime] $StartedAtUtc,
        [Parameter(Mandatory)][string] $InitialError,
        [AllowNull()][Nullable[int]] $InitialExitCode,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Layout,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $ExtraArguments
    )

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Artifact.FileName)
    $generalArchiveName = "${baseName}_DEGRADED.7z"
    $granularArchiveName = "${baseName}_GRANULAR_DEGRADED.7z"
    $generalDirectory = Join-Path $Layout.Work 'DatabaseDegraded'
    $granularDirectory = Join-Path $Layout.Work 'DatabaseGranular'
    $databaseDirectoryName = Get-SevenSafeFileName -Name ([string] $Configuration.Database.Name)
    $granularDatabaseDirectory = Join-Path (Join-Path $granularDirectory 'Granular') $databaseDirectoryName
    $null = New-Item -ItemType Directory -Path $generalDirectory, $granularDatabaseDirectory -Force

    $generalDumpPath = Join-Path $generalDirectory "${baseName}_DEGRADED.sql"
    Write-BackupLog -Level WARN -Stage 'Database/Degraded' -Message 'Normal dump failed; starting general dump with --force and granular recovery.'
    $generalResult = Invoke-SevenDatabaseDump `
        -MySqlDumpPath $Configuration.Tools.MySqlDump `
        -DefaultsExtraFile $Configuration.Database.DefaultsExtraFile `
        -DatabaseName $Configuration.Database.Name `
        -OutputPath $generalDumpPath `
        -ExtraArguments $ExtraArguments `
        -Force
    if (-not $generalResult.IsNonEmpty -and (Test-Path -LiteralPath $generalDumpPath -PathType Leaf)) {
        Remove-Item -LiteralPath $generalDumpPath -Force -ErrorAction SilentlyContinue
    }

    $objectResults = @()
    $listingError = ''
    $listingSucceeded = $false
    try {
        $objects = @(Get-SevenDatabaseObject `
                -MySqlPath $Configuration.Tools.MySql `
                -DefaultsExtraFile $Configuration.Database.DefaultsExtraFile `
                -DatabaseName $Configuration.Database.Name)
        $listingSucceeded = $true
        $usedNames = @{}
        foreach ($object in $objects) {
            $safeName = Get-SevenSafeFileName -Name $object.Name -UsedNames $usedNames
            $objectDumpPath = Join-Path $granularDatabaseDirectory "$safeName.sql"
            $timestamp = [DateTime]::UtcNow
            Write-BackupLog -Level INFO -Stage 'Database/Granular' -Message "Dumping $($object.ObjectType) '$($Configuration.Database.Name).$($object.Name)'."
            try {
                $result = Invoke-SevenDatabaseDump `
                    -MySqlDumpPath $Configuration.Tools.MySqlDump `
                    -DefaultsExtraFile $Configuration.Database.DefaultsExtraFile `
                    -DatabaseName $Configuration.Database.Name `
                    -DatabaseObject $object.Name `
                    -OutputPath $objectDumpPath `
                    -ExtraArguments $ExtraArguments
                if ($result.ExitCode -eq 0 -and $result.IsNonEmpty) {
                    $objectResults += [ordered]@{
                        name = $object.Name; objectType = $object.ObjectType; status = 'SUCCESS'
                        file = "Granular/$databaseDirectoryName/$safeName.sql"; sizeBytes = $result.Length
                        exitCode = $result.ExitCode; error = ''
                    }
                }
                else {
                    if (Test-Path -LiteralPath $objectDumpPath -PathType Leaf) { Remove-Item -LiteralPath $objectDumpPath -Force }
                    $errorMessage = ConvertTo-ManifestError -Message $result.StdErr
                    if ([string]::IsNullOrWhiteSpace($errorMessage)) { $errorMessage = "mysqldump failed with exit code $($result.ExitCode)." }
                    $failedPath = Join-Path $granularDatabaseDirectory "${safeName}_FAILED.txt"
                    @(
                        "Table: $($Configuration.Database.Name).$($object.Name)"
                        "ObjectType: $($object.ObjectType)"
                        "Error: $errorMessage"
                        "Timestamp: $($timestamp.ToString('o'))"
                    ) | Set-Content -LiteralPath $failedPath -Encoding utf8
                    $objectResults += [ordered]@{
                        name = $object.Name; objectType = $object.ObjectType; status = 'FAILED'
                        file = "Granular/$databaseDirectoryName/${safeName}_FAILED.txt"; sizeBytes = (Get-Item $failedPath).Length
                        exitCode = $result.ExitCode; error = $errorMessage
                    }
                    Write-BackupLog -Level WARN -Stage 'Database/Granular' -Message "$($Configuration.Database.Name).$($object.Name) failed: $errorMessage"
                }
            }
            catch {
                if (Test-Path -LiteralPath $objectDumpPath -PathType Leaf) { Remove-Item -LiteralPath $objectDumpPath -Force -ErrorAction SilentlyContinue }
                $errorMessage = ConvertTo-ManifestError -Message $_.Exception.Message
                $failedPath = Join-Path $granularDatabaseDirectory "${safeName}_FAILED.txt"
                @(
                    "Table: $($Configuration.Database.Name).$($object.Name)"
                    "ObjectType: $($object.ObjectType)"
                    "Error: $errorMessage"
                    "Timestamp: $($timestamp.ToString('o'))"
                ) | Set-Content -LiteralPath $failedPath -Encoding utf8
                $objectResults += [ordered]@{
                    name = $object.Name; objectType = $object.ObjectType; status = 'FAILED'
                    file = "Granular/$databaseDirectoryName/${safeName}_FAILED.txt"; sizeBytes = (Get-Item $failedPath).Length
                    exitCode = $null; error = $errorMessage
                }
                Write-BackupLog -Level WARN -Stage 'Database/Granular' -Message "$($Configuration.Database.Name).$($object.Name) failed: $errorMessage"
            }
        }
    }
    catch {
        $listingError = ConvertTo-ManifestError -Message $_.Exception.Message
        Write-BackupLog -Level ERROR -Stage 'Database/Granular' -Message $listingError
    }

    $generalError = ConvertTo-ManifestError -Message $generalResult.StdErr
    $failedTableMatches = @([regex]::Matches($generalError, '(?i)(?:table|view)[^`]*`(?<name>[^`]+)`') | ForEach-Object { $_.Groups['name'].Value } | Select-Object -Unique)
    $manifest = [ordered]@{
        schemaVersion = 1
        status = 'DEGRADED'
        instanceName = [string] $Configuration.InstanceName
        databaseName = [string] $Configuration.Database.Name
        runId = $RunId
        startedAtUtc = $StartedAtUtc.ToString('o')
        completedAtUtc = [DateTime]::UtcNow.ToString('o')
        strategy = 'force+granular'
        archives = @(
            [ordered]@{ role = 'GENERAL'; fileName = $generalArchiveName }
            [ordered]@{ role = 'GRANULAR'; fileName = $granularArchiveName }
        )
        initialFailure = [ordered]@{ exitCode = $InitialExitCode; error = (ConvertTo-ManifestError -Message $InitialError) }
        generalDump = [ordered]@{
            file = if ($generalResult.IsNonEmpty) { [System.IO.Path]::GetFileName($generalDumpPath) } else { $null }
            sizeBytes = $generalResult.Length
            exitCode = $generalResult.ExitCode
            error = $generalError
            referencedObjects = $failedTableMatches
        }
        granular = [ordered]@{
            listingSucceeded = $listingSucceeded
            listingError = $listingError
            objects = $objectResults
        }
    }
    $manifestDirectories = @($generalDirectory)
    if ($listingSucceeded) { $manifestDirectories += $granularDirectory }
    Write-DatabaseManifest -Manifest $manifest -Directories $manifestDirectories

    $errors = @()
    $publishedRoles = @()
    if ($generalResult.IsNonEmpty) {
        $generalArchivePath = Join-Path $Layout.Work $generalArchiveName
        try {
            $null = New-SevenArchive -SevenZipPath $Configuration.Tools.SevenZip -SourcePath $generalDirectory -ArchivePath $generalArchivePath `
                -CompressionLevel ([int] $Configuration.Archive.CompressionLevel) -CpuLimitPercent ([int] $Configuration.Archive.CpuLimitPercent) -ContentsOnly
            Publish-DatabaseWorkArchive -WorkArchivePath $generalArchivePath -Artifact $Artifact -Configuration $Configuration -Layout $Layout
            $publishedRoles += 'GENERAL'
        }
        catch { $errors += "General degraded archive: $($_.Exception.Message)" }
    }
    else {
        $errors += 'General dump with --force was empty.'
    }

    if ($listingSucceeded) {
        $granularArchivePath = Join-Path $Layout.Work $granularArchiveName
        try {
            $null = New-SevenArchive -SevenZipPath $Configuration.Tools.SevenZip -SourcePath $granularDirectory -ArchivePath $granularArchivePath `
                -CompressionLevel ([int] $Configuration.Archive.CompressionLevel) -CpuLimitPercent ([int] $Configuration.Archive.CpuLimitPercent) -ContentsOnly
            Publish-DatabaseWorkArchive -WorkArchivePath $granularArchivePath -Artifact $Artifact -Configuration $Configuration -Layout $Layout
            $publishedRoles += 'GRANULAR'
        }
        catch { $errors += "Granular degraded archive: $($_.Exception.Message)" }
    }
    else {
        $errors += "Granular enumeration failed: $listingError"
    }

    if ($publishedRoles.Count -eq 2) {
        Write-BackupLog -Level WARN -Stage 'Database/Degraded' -Message "Degraded backup published as '$generalArchiveName' and '$granularArchiveName'."
        return 'DEGRADED'
    }
    throw "Database fallback was incomplete. $($errors -join ' ')"
}

function Invoke-DatabaseBackup {
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Layout
    )

    $startedAtUtc = [DateTime]::UtcNow
    $artifact = New-ArtifactInfo -InstanceName $Configuration.InstanceName -BackupType Database -RunId $RunId
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($artifact.FileName)
    $sourceDirectory = Join-Path $Layout.Work 'DatabaseNormal'
    $dumpPath = Join-Path $sourceDirectory "$baseName.sql"
    $workArchivePath = Join-Path $Layout.Work $artifact.FileName
    [string[]] $extraArguments = @()
    if ($Configuration.Database.Contains('ExtraArguments') -and $null -ne $Configuration.Database.ExtraArguments) {
        $extraArguments = @($Configuration.Database.ExtraArguments)
    }

    $normalResult = $null
    $initialError = ''
    $initialExitCode = $null
    try {
        Write-BackupLog -Level INFO -Stage 'Database/Dump' -Message "Creating database dump '$dumpPath'."
        $normalResult = Invoke-SevenDatabaseDump -MySqlDumpPath $Configuration.Tools.MySqlDump `
            -DefaultsExtraFile $Configuration.Database.DefaultsExtraFile -DatabaseName $Configuration.Database.Name `
            -OutputPath $dumpPath -ExtraArguments $extraArguments
        $initialExitCode = $normalResult.ExitCode
        if ($normalResult.ExitCode -ne 0) {
            $initialError = "mysqldump failed with exit code $($normalResult.ExitCode). $($normalResult.StdErr)"
        }
        elseif (-not $normalResult.IsNonEmpty) {
            $initialError = "mysqldump created an empty dump: $dumpPath"
        }
    }
    catch {
        $initialError = $_.Exception.Message
    }

    if (-not [string]::IsNullOrWhiteSpace($initialError)) {
        if (Test-Path -LiteralPath $dumpPath -PathType Leaf) {
            Remove-Item -LiteralPath $dumpPath -Force -ErrorAction SilentlyContinue
        }
        return Invoke-DegradedDatabaseBackup -RunId $RunId -Artifact $artifact -StartedAtUtc $startedAtUtc `
            -InitialError $initialError -InitialExitCode $initialExitCode -Configuration $Configuration -Layout $Layout -ExtraArguments $extraArguments
    }
    $dump = $normalResult.File

    $manifest = [ordered]@{
        schemaVersion = 1; status = 'SUCCESS'; instanceName = [string] $Configuration.InstanceName
        databaseName = [string] $Configuration.Database.Name; runId = $RunId
        startedAtUtc = $startedAtUtc.ToString('o'); completedAtUtc = [DateTime]::UtcNow.ToString('o')
        strategy = 'normal'
        archives = @([ordered]@{ role = 'GENERAL'; fileName = $artifact.FileName })
        dumps = @([ordered]@{ name = [string] $Configuration.Database.Name; objectType = 'DATABASE'; status = 'SUCCESS'; file = $dump.Name; sizeBytes = $dump.Length; exitCode = 0; error = '' })
    }
    Write-DatabaseManifest -Manifest $manifest -Directories @($sourceDirectory)

    Write-BackupLog -Level INFO -Stage 'Database/Archive' -Message "Creating archive '$workArchivePath'."
    $null = New-SevenArchive -SevenZipPath $Configuration.Tools.SevenZip -SourcePath $sourceDirectory -ArchivePath $workArchivePath `
        -CompressionLevel ([int] $Configuration.Archive.CompressionLevel) -CpuLimitPercent ([int] $Configuration.Archive.CpuLimitPercent) -ContentsOnly
    Publish-DatabaseWorkArchive -WorkArchivePath $workArchivePath -Artifact $artifact -Configuration $Configuration -Layout $Layout
    return 'SUCCESS'
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
        -CompressionLevel ([int] $Configuration.Archive.CompressionLevel) `
        -CpuLimitPercent ([int] $Configuration.Archive.CpuLimitPercent)

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
    foreach ($logFile in Get-ChildItem -LiteralPath $Layout.Logs -Filter '*.log' -File) {
        if ($logFile.FullName -eq $currentLogPath) {
            continue
        }

        try {
            $dateParts = Get-LogDateInfo -FileName $logFile.Name
            if ($dateParts.Timestamp -lt $logCutoff) {
                Remove-Item -LiteralPath $logFile.FullName -Force -ErrorAction Stop
                Write-BackupLog -Level INFO -Stage 'Retention/Log' -Message "Removed expired log '$($logFile.FullName)'."
            }
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
    $storageValidated = $false

    try {
        if ([string]::IsNullOrWhiteSpace($RequestedConfigPath)) {
            $RequestedConfigPath = Join-Path $PSScriptRoot 'config.psd1'
        }

        $version = Get-ApplicationVersion
        $configuration = Read-BackupConfiguration -Path $RequestedConfigPath -BackupTypes $backupTypes
        $layout = New-RuntimeLayout `
            -RuntimeRoot $configuration.Paths.RuntimeRoot `
            -CompletedRoot $configuration.Paths.CompletedRoot `
            -LogRoot $configuration.Paths.LogRoot `
            -RunId $runId `
            -BackupTypes $backupTypes
        $null = Initialize-BackupLog `
            -LogRoot $layout.Logs `
            -InstanceName $configuration.InstanceName `
            -RunId $runId `
            -Mode $RequestedMode `
            -Version $version
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
        $storageValidated = $true

        $operationSucceeded = $true
        $operationDegraded = $false
        foreach ($backupType in $backupTypes) {
            if (-not (Invoke-PendingRetry -BackupType $backupType -Configuration $configuration -Layout $layout)) {
                $operationSucceeded = $false
            }
        }

        foreach ($backupType in $backupTypes) {
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                if ($backupType -eq 'Database') {
                    $databaseStatus = Invoke-DatabaseBackup -RunId $runId -Configuration $configuration -Layout $layout
                    if ($databaseStatus -eq 'DEGRADED') {
                        $operationDegraded = $true
                        Write-BackupLog -Level WARN -Stage 'Database/Complete' -Message "Pipeline completed as DEGRADED in $([math]::Round($stopwatch.Elapsed.TotalSeconds, 1)) seconds."
                    }
                    else {
                        Write-BackupLog -Level INFO -Stage 'Database/Complete' -Message "Pipeline completed in $([math]::Round($stopwatch.Elapsed.TotalSeconds, 1)) seconds."
                    }
                }
                else {
                    Invoke-FiscalBackup -RunId $runId -Configuration $configuration -Layout $layout
                    Write-BackupLog -Level INFO -Stage 'Fiscal/Complete' -Message "Pipeline completed in $([math]::Round($stopwatch.Elapsed.TotalSeconds, 1)) seconds."
                }
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
            $exitCode = 1
        }
        elseif (-not $maintenanceSucceeded -and $operationDegraded) {
            Write-BackupLog -Level ERROR -Stage 'Complete' -Message 'A degraded backup was published, but cleanup or retention also failed.'
            $exitCode = 1
        }
        elseif (-not $maintenanceSucceeded) {
            Write-BackupLog -Level ERROR -Stage 'Complete' -Message 'Backups completed, but cleanup or retention failed.'
            $exitCode = 4
        }
        elseif ($operationDegraded) {
            Write-BackupLog -Level WARN -Stage 'Complete' -Message 'Execution completed with a published DEGRADED database backup.'
            $exitCode = 5
        }
        else {
            Write-BackupLog -Level INFO -Stage 'Complete' -Message 'Execution completed successfully.'
            $exitCode = 0
        }

        try {
            Publish-ExecutionLog -Configuration $configuration
        }
        catch {
            Write-BackupLog -Level ERROR -Stage 'Log/Upload' -Message $_.Exception.Message
            return 1
        }

        return $exitCode
    }
    catch {
        if ($logInitialized) {
            Write-BackupLog -Level ERROR -Stage 'Startup' -Message $_.Exception.Message

            if ($storageValidated) {
                try {
                    Publish-ExecutionLog -Configuration $configuration
                }
                catch {
                    Write-BackupLog -Level ERROR -Stage 'Log/Upload' -Message $_.Exception.Message
                }
            }
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
