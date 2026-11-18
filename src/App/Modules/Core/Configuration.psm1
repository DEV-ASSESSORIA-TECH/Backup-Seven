Set-StrictMode -Version Latest

function Resolve-DBPath {
    param([string] $Path, [string] $BasePath)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'A required path is empty.' }
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { $Path = Join-Path $BasePath $Path }
    $resolved = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $ancestor = $resolved
    while ($ancestor) {
        if (Test-Path -LiteralPath $ancestor) {
            $item = Get-Item -LiteralPath $ancestor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked paths are not allowed: $ancestor" }
        }
        $ancestor = Split-Path -Parent $ancestor
    }
    return $resolved
}

function Test-DBPathWithin {
    param([string] $Path, [string] $Root)
    return $Path.Equals($Root, [StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith($Root.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-DBIdentifier {
    param([string] $Value)
    if ($Value -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$' -or $Value -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
        throw "Invalid DBBackup identifier: $Value"
    }
}

function Get-DBDefaultPath {
    <#
    Install layout: <root>\Instances\<instance>\config.psd1. Runtime holds
    plaintext work and stays private inside the instance; Completed and Logs
    are operator folders at the root, one subfolder per instance.
    #>
    param([string] $InstanceName)
    return @{ RuntimeRoot = 'Runtime'; CompletedRoot = "../../Completed/$InstanceName"; LogRoot = "../../Logs/$InstanceName" }
}

function Read-DBConfiguration {
    <#
    Schema 2: an instance (destination credentials, age recipients, schedule,
    lock and folders) runs a list of jobs; each job has its own provider
    (MySQL, SQLAnywhere or Directory) and its own remote destination.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path, [Collections.IDictionary] $Data)
    $Path = [IO.Path]::GetFullPath($Path)
    $c = if ($null -ne $Data) { $Data } else { Import-PowerShellDataFile -LiteralPath $Path }
    if (-not $c.Contains('SchemaVersion') -or $c.SchemaVersion -ne 2) {
        if ($c.Contains('SchemaVersion') -and $c.SchemaVersion -eq 1) { throw 'Configuration schema 1 (DBBackup 1.x): run Setup to create the 2.0 configuration.' }
        throw 'SchemaVersion must be 2.'
    }
    foreach ($key in @('InstanceName', 'Tools', 'Storage', 'Encryption', 'Jobs', 'Archive', 'Retention')) {
        if (-not $c.Contains($key)) { throw "Missing configuration key: $key" }
    }
    Assert-DBIdentifier $c.InstanceName
    if (-not $c.Contains('Paths')) { $c.Paths = Get-DBDefaultPath $c.InstanceName }
    foreach ($key in @('Tools', 'Storage', 'Encryption', 'Paths', 'Archive', 'Retention')) {
        if ($c[$key] -isnot [Collections.IDictionary]) { throw "Section must be a hashtable: $key" }
    }
    $defaultPaths = Get-DBDefaultPath $c.InstanceName
    foreach ($key in $defaultPaths.Keys) { if (-not $c.Paths.Contains($key)) { $c.Paths[$key] = $defaultPaths[$key] } }
    $base = Split-Path -Parent $Path
    $c.ConfigPath = $Path
    $c.InstanceRoot = $base
    $c.SecretsRoot = Resolve-DBPath 'Secrets' $base
    foreach ($key in @('RuntimeRoot', 'CompletedRoot', 'LogRoot')) {
        $c.Paths[$key] = Resolve-DBPath ([string] $c.Paths[$key]) $base
        if (Test-DBPathWithin $base $c.Paths[$key]) { throw 'State paths must not contain the configuration directory.' }
        if ((Test-DBPathWithin $c.SecretsRoot $c.Paths[$key]) -or (Test-DBPathWithin $c.Paths[$key] $c.SecretsRoot)) {
            throw 'Secrets and state paths must not overlap.'
        }
    }
    $roots = @($c.Paths.RuntimeRoot, $c.Paths.CompletedRoot, $c.Paths.LogRoot)
    if (-not [IO.Path]::GetPathRoot($c.Paths.RuntimeRoot).Equals([IO.Path]::GetPathRoot($c.Paths.CompletedRoot), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Runtime and Completed must be on the same volume for atomic bundle moves.'
    }
    for ($i = 0; $i -lt $roots.Count; $i++) {
        for ($j = $i + 1; $j -lt $roots.Count; $j++) {
            if ((Test-DBPathWithin $roots[$i] $roots[$j]) -or (Test-DBPathWithin $roots[$j] $roots[$i])) { throw 'State paths must not overlap.' }
        }
    }
    foreach ($key in @($c.Tools.Keys)) { $c.Tools[$key] = Resolve-DBPath ([string] $c.Tools[$key]) $base }
    $c.Storage.ConfigPath = Resolve-DBPath ([string] $c.Storage.ConfigPath) $base
    $c.Encryption.RecipientsFile = Resolve-DBPath ([string] $c.Encryption.RecipientsFile) $base
    $secrets = @($c.Storage.ConfigPath, $c.Encryption.RecipientsFile)

    $entries = @($c.Jobs)
    if ($entries.Count -eq 0) { throw 'At least one job is required.' }
    $jobs = @()
    $ids = @{}
    foreach ($entry in $entries) {
        if ($entry -isnot [Collections.IDictionary]) { throw 'Each job must be a hashtable.' }
        foreach ($key in $entry.Keys) {
            if ($key -notin @('Id','Provider','RemoteRoot','Database','CredentialFile','ExtraArguments','SourcePath')) { throw "Unknown job key: $key" }
        }
        foreach ($key in @('Id','Provider','RemoteRoot')) { if (-not $entry.Contains($key)) { throw "Missing job field: $key" } }
        $id = [string] $entry.Id
        Assert-DBIdentifier $id
        # Job IDs become folder names on Windows: unique without regard to case.
        # 'Logs' is the remote folder of the run logs.
        if ($ids.ContainsKey($id.ToLowerInvariant()) -or $id -ieq 'logs') { throw "Duplicate or reserved job ID: $id" }
        $ids[$id.ToLowerInvariant()] = $true
        $provider = [string] $entry.Provider
        if ($provider -cnotin @('MySQL','SQLAnywhere','Directory')) { throw "Job $id`: Provider must be MySQL, SQLAnywhere or Directory." }
        $remoteRoot = ConvertTo-DBRemoteRoot ([string] $entry.RemoteRoot)
        $job = [ordered]@{
            Id = $id; Provider = $provider; RemoteRoot = $remoteRoot; Destination = "$remoteRoot/$id"
            Database = $null; CredentialFile = $null; ExtraArguments = @(); SourcePath = $null
        }
        if ($provider -eq 'Directory') {
            foreach ($key in @('Database','CredentialFile','ExtraArguments')) { if ($entry.Contains($key)) { throw "Job $id`: $key is not valid for Directory." } }
            if (-not $entry.Contains('SourcePath')) { throw "Job $id`: SourcePath is required." }
            $source = Resolve-DBPath ([string] $entry.SourcePath) $base
            foreach ($root in @($base) + $roots) {
                if ((Test-DBPathWithin $source $root) -or (Test-DBPathWithin $root $source)) { throw "Job $id`: the directory source overlaps the instance or its state." }
            }
            $job.SourcePath = $source
        }
        else {
            if ($entry.Contains('SourcePath')) { throw "Job $id`: SourcePath is only valid for Directory." }
            if (-not $entry.Contains('Database') -or [string]::IsNullOrWhiteSpace([string] $entry.Database)) { throw "Job $id`: Database is required." }
            if (-not $entry.Contains('CredentialFile')) { throw "Job $id`: CredentialFile is required." }
            $job.Database = [string] $entry.Database
            $job.CredentialFile = Resolve-DBPath ([string] $entry.CredentialFile) $base
            $secrets += $job.CredentialFile
            if ($entry.Contains('ExtraArguments')) {
                if ($provider -ne 'MySQL') { throw "Job $id`: ExtraArguments is only valid for MySQL." }
                $job.ExtraArguments = @($entry.ExtraArguments | ForEach-Object { [string] $_ })
            }
        }
        $jobs += [pscustomobject] $job
    }
    for ($i = 0; $i -lt $jobs.Count; $i++) {
        for ($j = $i + 1; $j -lt $jobs.Count; $j++) {
            if (Test-DBRemoteOverlap $jobs[$i].Destination $jobs[$j].Destination) { throw "Jobs $($jobs[$i].Id) and $($jobs[$j].Id) share a remote destination." }
        }
    }
    foreach ($secret in $secrets) {
        if (-not (Test-DBPathWithin $secret $c.SecretsRoot)) { throw 'Secret files must belong to this instance Secrets directory.' }
    }
    $required = @('SevenZip', 'Age', 'Rclone')
    if (@($jobs | Where-Object Provider -EQ 'MySQL').Count) { $required += @('MySql', 'MySqlDump') }
    if (@($jobs | Where-Object Provider -EQ 'SQLAnywhere').Count) { $required += 'DbBackup' }
    foreach ($key in $required) { if (-not $c.Tools.Contains($key)) { throw "Missing tool: $key" } }
    if ([int] $c.Archive.CompressionLevel -notin 0..9 -or [int] $c.Archive.CpuLimitPercent -notin 1..100) { throw 'Invalid Archive settings.' }
    foreach ($key in @('CompletedDays', 'LogDays')) {
        $value = 0
        if (-not [int]::TryParse([string] $c.Retention[$key], [ref] $value) -or $value -lt 1) { throw "Invalid Retention.$key" }
    }
    if (-not $c.Retention.Contains('KeepLocalPayload')) { $c.Retention.KeepLocalPayload = $true }
    if ($c.Retention.KeepLocalPayload -isnot [bool]) { throw 'Retention.KeepLocalPayload must be boolean.' }
    if (-not $c.Storage.Contains('Destination')) { $c.Storage.Destination = 's3' }
    if ([string] $c.Storage.Destination -cnotmatch '^[a-z0-9]+([-_][a-z0-9]+)*$') { throw 'Storage.Destination must be a lowercase identifier.' }
    $c.Jobs = $jobs
    if (-not $c.Contains('Execution')) { $c.Execution = @{} }
    if ($c.Execution -isnot [Collections.IDictionary]) { throw 'Execution must be a hashtable.' }
    $defaults = @{ToolTimeoutSeconds=21600;RunTimeoutSeconds=39600;ReserveBytes=1073741824;EstimatedDatabaseBytes=0}
    foreach ($key in $defaults.Keys) {
        if (-not $c.Execution.Contains($key)) { $c.Execution[$key] = $defaults[$key] }
        [long] $number = 0
        if (-not [long]::TryParse([string] $c.Execution[$key], [ref] $number) -or $number -lt 0) { throw "Invalid Execution.$key" }
    }
    $toolTimeout = [long] $c.Execution.ToolTimeoutSeconds
    if ($toolTimeout -lt 1 -or $toolTimeout -gt 86400) { throw 'ToolTimeoutSeconds must be 1..86400.' }
    # Whole run, every job included. The scheduled task limit is derived from it
    # (rounded up to hours, plus one hour) so DBBackup stops first, records the
    # failure and cleans up instead of being killed by the Task Scheduler.
    $runTimeout = [long] $c.Execution.RunTimeoutSeconds
    if ($runTimeout -lt 600 -or $runTimeout -gt 255600) { throw 'RunTimeoutSeconds must be 600..255600.' }
    if (-not $c.Contains('Monitoring')) { $c.Monitoring = @{Enabled=$false} }
    if ($c.Monitoring -isnot [Collections.IDictionary] -or -not $c.Monitoring.Contains('Enabled') -or $c.Monitoring.Enabled -isnot [bool]) { throw 'Monitoring.Enabled must be boolean.' }
    if ($c.Monitoring.Enabled) {
        if ([string] $c.Monitoring.Service -cnotmatch '^[a-z0-9]+([-_][a-z0-9]+)*$') { throw 'Monitoring.Service must identify the protected service in lowercase.' }
        $c.Monitoring.TextfileDirectory = Resolve-DBPath ([string] $c.Monitoring.TextfileDirectory) $base
        foreach ($map in @('BackupIds','Criticality','ExpectedIntervalHours')) {
            if (-not $c.Monitoring.Contains($map)) { $c.Monitoring[$map] = @{} }
            if ($c.Monitoring[$map] -isnot [Collections.IDictionary]) { throw "Monitoring.$map must be a hashtable." }
            foreach ($id in $c.Monitoring[$map].Keys) { if ($id -cnotin @($jobs.Id)) { throw "Unknown monitoring job: $id" } }
        }
        $metricIds = @{}
        foreach ($j in $jobs) {
            if (-not $c.Monitoring.BackupIds.Contains($j.Id)) { $c.Monitoring.BackupIds[$j.Id] = "$($c.InstanceName.ToLowerInvariant())-$($j.Id.ToLowerInvariant())" }
            $id = [string] $c.Monitoring.BackupIds[$j.Id]
            if ($id -cnotmatch '^[a-z0-9]+([-_][a-z0-9]+)*$' -or $metricIds.ContainsKey($id)) { throw 'Invalid or duplicate Monitoring.BackupIds.' }
            $metricIds[$id] = $true
            if (-not $c.Monitoring.Criticality.Contains($j.Id)) { $c.Monitoring.Criticality[$j.Id] = 'alta' }
            if ($c.Monitoring.Criticality[$j.Id] -cnotin @('alta','baixa')) { throw 'Monitoring.Criticality must be alta or baixa.' }
            if ($c.Monitoring.ExpectedIntervalHours.Contains($j.Id)) {
                [double] $hours = 0
                if (-not [double]::TryParse([string] $c.Monitoring.ExpectedIntervalHours[$j.Id], [ref] $hours) -or -not [double]::IsFinite($hours) -or $hours -le 0) { throw 'ExpectedIntervalHours must be positive and finite.' }
            }
        }
    }
    return $c
}

function ConvertTo-DBRemoteRoot {
    <#
    Storage.RemoteRoot is the complete destination of an instance
    (remote:bucket[/prefix]); artifacts go to <RemoteRoot>/<job>/yyyy/MM/dd/.
    The instance name is not added, so it can be chosen freely. Returns the
    value without a trailing separator; rejects empty or relative segments.
    #>
    param([string] $Value)
    if ($Value -notmatch '^([A-Za-z0-9_-]+):([^\r\n]+)$') { throw 'Storage.RemoteRoot must use remote:bucket/prefix syntax.' }
    $remote = $Matches[1]
    $path = $Matches[2].TrimEnd('/')
    $relative = $path.TrimStart('/')
    if (-not $relative) { throw 'Storage.RemoteRoot must name a bucket: remote:bucket[/prefix].' }
    foreach ($segment in $relative.Split('/')) {
        if ($segment -in @('', '.', '..') -or $segment -match '[\\\x00-\x1f]') { throw "Storage.RemoteRoot has an invalid path segment: '$segment'." }
    }
    return "${remote}:$path"
}

function Test-DBRemoteOverlap {
    <# True when two destinations are the same prefix or one contains the other (S3 keys are case-sensitive). #>
    param([string] $First, [string] $Second)
    return $First -ceq $Second -or $First.StartsWith($Second + '/', [StringComparison]::Ordinal) -or $Second.StartsWith($First + '/', [StringComparison]::Ordinal)
}

function Assert-DBInstanceIsolation {
    param([Collections.IDictionary] $Configuration, [string] $InstancesRoot)
    if (-not (Test-Path -LiteralPath $InstancesRoot)) { return }
    foreach ($file in Get-ChildItem -LiteralPath $InstancesRoot -Filter config.psd1 -File -Recurse -ErrorAction Stop) {
        if ($file.FullName -eq $Configuration.ConfigPath) { continue }
        # A 1.x configuration left beside 2.0 instances is not an active instance.
        $schema = (Import-PowerShellDataFile -LiteralPath $file.FullName).SchemaVersion
        if ($schema -ne 2) { continue }
        $other = Read-DBConfiguration $file.FullName
        if ($other.InstanceName -eq $Configuration.InstanceName) { throw "Duplicate InstanceName: $($other.InstanceName)" }
        # Each job owns its destination (<RemoteRoot>/<job>): sharing it would
        # mix backups of different sources in the same dated folders.
        foreach ($mine in $Configuration.Jobs) {
            foreach ($theirs in $other.Jobs) {
                if ($mine.Destination -match 'REPLACE_' -or $theirs.Destination -match 'REPLACE_') { continue }
                if (Test-DBRemoteOverlap $mine.Destination $theirs.Destination) {
                    throw "Job $($mine.Id) shares the remote destination $($theirs.Destination) with $($other.InstanceName)/$($theirs.Id); use a distinct bucket, prefix or job ID."
                }
            }
        }
        if ($Configuration.Monitoring.Enabled -and $other.Monitoring.Enabled -and $Configuration.Monitoring.Service -ceq $other.Monitoring.Service) {
            foreach ($id in $Configuration.Monitoring.BackupIds.Values) {
                if ($id -cin @($other.Monitoring.BackupIds.Values)) { throw 'Instances have duplicate monitoring identities on this host.' }
            }
        }
        foreach ($a in @($Configuration.InstanceRoot, $Configuration.SecretsRoot) + @($Configuration.Paths.Values)) {
            foreach ($b in @($other.InstanceRoot, $other.SecretsRoot) + @($other.Paths.Values)) {
                if ((Test-DBPathWithin $a $b) -or (Test-DBPathWithin $b $a)) { throw 'Instances share configuration or secret directories.' }
            }
        }
    }
}

function Get-DBInstanceConfigPath {
    <# config.psd1 of every instance under InstancesRoot, sorted by instance name. #>
    param([Parameter(Mandatory)][string] $InstancesRoot)
    if (-not (Test-Path -LiteralPath $InstancesRoot -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $InstancesRoot -Directory -Force | Sort-Object Name |
        ForEach-Object { Join-Path $_.FullName 'config.psd1' } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
}

function Select-DBConfigPath {
    <#
    Used by the .bat launchers instead of asking for a path: one instance is
    chosen automatically, several are listed by number. A full path to a
    config.psd1 is still accepted.
    #>
    param([Parameter(Mandatory)][string] $InstancesRoot)
    $found = @(Get-DBInstanceConfigPath $InstancesRoot)
    if ($found.Count -eq 1) {
        "Instancia: $(Split-Path -Leaf (Split-Path -Parent $found[0])) ($($found[0]))" | Out-Host
        return $found[0]
    }
    if ($found.Count) {
        'Instancias encontradas:' | Out-Host
        for ($i = 0; $i -lt $found.Count; $i++) { '  {0}) {1}  ({2})' -f ($i + 1), (Split-Path -Leaf (Split-Path -Parent $found[$i])), $found[$i] | Out-Host }
        $prompt = 'Numero da instancia (ou caminho completo do config.psd1)'
    }
    else {
        "Nenhuma instancia encontrada em $InstancesRoot." | Out-Host
        $prompt = 'Caminho completo do config.psd1'
    }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $answer = ([string] (Read-Host $prompt)).Trim().Trim('"')
        if ($answer -match '^\d+$' -and [int] $answer -ge 1 -and [int] $answer -le $found.Count) { return $found[[int] $answer - 1] }
        if ($answer -and $answer -notmatch '^\d+$' -and (Test-Path -LiteralPath $answer -PathType Leaf)) { return [IO.Path]::GetFullPath($answer) }
        Write-Warning 'Opcao invalida.'
    }
    throw 'Nenhuma configuracao selecionada.'
}

Export-ModuleMember -Function Get-DBInstanceConfigPath, Select-DBConfigPath, Get-DBDefaultPath, Read-DBConfiguration, Resolve-DBPath, Test-DBPathWithin, Assert-DBIdentifier, ConvertTo-DBRemoteRoot, Test-DBRemoteOverlap, Assert-DBInstanceIsolation
