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

function Read-DBConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path, [Collections.IDictionary] $Data)
    $Path = [IO.Path]::GetFullPath($Path)
    $c = if ($null -ne $Data) { $Data } else { Import-PowerShellDataFile -LiteralPath $Path }
    if (-not $c.Contains('SchemaVersion') -or $c.SchemaVersion -ne 1) { throw 'SchemaVersion must be 1.' }
    foreach ($key in @('InstanceName', 'Provider', 'Tools', 'Database', 'Storage', 'Encryption', 'Paths', 'Archive', 'Retention')) {
        if (-not $c.Contains($key)) { throw "Missing configuration key: $key" }
    }
    Assert-DBIdentifier $c.InstanceName
    if ($c.Provider -cnotin @('MySQL', 'SQLAnywhere')) { throw 'Provider must be MySQL or SQLAnywhere.' }
    foreach ($key in @('Tools', 'Database', 'Storage', 'Encryption', 'Paths', 'Archive', 'Retention')) {
        if ($c[$key] -isnot [Collections.IDictionary]) { throw "Section must be a hashtable: $key" }
    }
    if (-not $c.Database.Contains('Name') -or [string]::IsNullOrWhiteSpace($c.Database.Name)) { throw 'Database.Name is required.' }
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
    foreach ($key in @('SevenZip', 'Age', 'Rclone')) {
        if (-not $c.Tools.Contains($key)) { throw "Missing tool: $key" }
    }
    $c.Storage.ConfigPath = Resolve-DBPath ([string] $c.Storage.ConfigPath) $base
    $c.Storage.RemoteRoot = ConvertTo-DBRemoteRoot ([string] $c.Storage.RemoteRoot)
    $c.Encryption.RecipientsFile = Resolve-DBPath ([string] $c.Encryption.RecipientsFile) $base
    $credentialKey = if ($c.Provider -eq 'MySQL') { 'DefaultsExtraFile' } else { 'ConnectionOptionsFile' }
    $c.Database[$credentialKey] = Resolve-DBPath ([string] $c.Database[$credentialKey]) $base
    foreach ($secret in @($c.Database[$credentialKey], $c.Storage.ConfigPath, $c.Encryption.RecipientsFile)) {
        if (-not (Test-DBPathWithin $secret $c.SecretsRoot)) { throw 'Secret files must belong to this instance Secrets directory.' }
    }
    if (-not $c.Database.Contains('ExtraArguments')) { $c.Database.ExtraArguments = @() }
    if ([int] $c.Archive.CompressionLevel -notin 0..9 -or [int] $c.Archive.CpuLimitPercent -notin 1..100) { throw 'Invalid Archive settings.' }
    foreach ($key in @('CompletedDays', 'LogDays')) {
        $value = 0
        if (-not [int]::TryParse([string] $c.Retention[$key], [ref] $value) -or $value -lt 1) { throw "Invalid Retention.$key" }
    }
    if (-not $c.Retention.Contains('KeepLocalPayload')) { $c.Retention.KeepLocalPayload = $true }
    if ($c.Retention.KeepLocalPayload -isnot [bool]) { throw 'Retention.KeepLocalPayload must be boolean.' }
    if (-not $c.Storage.Contains('Destination')) { $c.Storage.Destination = 's3' }
    if ([string] $c.Storage.Destination -cnotmatch '^[a-z0-9]+([-_][a-z0-9]+)*$') { throw 'Storage.Destination must be a lowercase identifier.' }
    $jobs = @([pscustomobject]@{ Id = 'database'; Provider = $c.Provider; SourcePath = $null })
    if (-not $c.Contains('Directories')) { $c.Directories = @() }
    $ids = @{ database = $true }
    foreach ($entry in $c.Directories) {
        Assert-DBIdentifier ([string] $entry.Id)
        if ($ids.ContainsKey([string] $entry.Id)) { throw "Duplicate or reserved job ID: $($entry.Id)" }
        $ids[[string] $entry.Id] = $true
        $source = Resolve-DBPath ([string] $entry.SourcePath) $base
        foreach ($root in @($base) + $roots) {
            if ((Test-DBPathWithin $source $root) -or (Test-DBPathWithin $root $source)) { throw 'A directory source overlaps the instance or state.' }
        }
        $jobs += [pscustomobject]@{ Id = [string] $entry.Id; Provider = 'Directory'; SourcePath = $source }
    }
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
        $other = Read-DBConfiguration $file.FullName
        if ($other.InstanceName -eq $Configuration.InstanceName) { throw "Duplicate InstanceName: $($other.InstanceName)" }
        # Each instance owns its destination prefix: sharing it would mix jobs
        # of different databases in the same dated folders.
        $placeholder = $Configuration.Storage.RemoteRoot -match 'REPLACE_' -or $other.Storage.RemoteRoot -match 'REPLACE_'
        if (-not $placeholder -and (Test-DBRemoteOverlap $Configuration.Storage.RemoteRoot $other.Storage.RemoteRoot)) {
            throw "Instances share the remote destination $($other.Storage.RemoteRoot) ($($other.InstanceName)); use a distinct bucket or prefix."
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

Export-ModuleMember -Function Read-DBConfiguration, Resolve-DBPath, Test-DBPathWithin, Assert-DBIdentifier, ConvertTo-DBRemoteRoot, Test-DBRemoteOverlap, Assert-DBInstanceIsolation
