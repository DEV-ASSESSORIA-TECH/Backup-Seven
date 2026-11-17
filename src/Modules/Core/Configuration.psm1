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
    param([Parameter(Mandatory)][string] $Path)
    $Path = [IO.Path]::GetFullPath($Path)
    $c = Import-PowerShellDataFile -LiteralPath $Path
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
    if ([string] $c.Storage.RemoteRoot -notmatch '^[A-Za-z0-9_-]+:[^\r\n]+$') { throw 'Storage.RemoteRoot must use remote:path syntax.' }
    $c.Encryption.RecipientsFile = Resolve-DBPath ([string] $c.Encryption.RecipientsFile) $base
    $credentialKey = if ($c.Provider -eq 'MySQL') { 'DefaultsExtraFile' } else { 'ConnectionOptionsFile' }
    $c.Database[$credentialKey] = Resolve-DBPath ([string] $c.Database[$credentialKey]) $base
    if (-not $c.Database.Contains('ExtraArguments')) { $c.Database.ExtraArguments = @() }
    if ([int] $c.Archive.CompressionLevel -notin 0..9 -or [int] $c.Archive.CpuLimitPercent -notin 1..100) { throw 'Invalid Archive settings.' }
    foreach ($key in @('CompletedDays', 'LogDays')) {
        $value = 0
        if (-not [int]::TryParse([string] $c.Retention[$key], [ref] $value) -or $value -lt 1) { throw "Invalid Retention.$key" }
    }
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
    return $c
}

function Assert-DBInstanceIsolation {
    param([Collections.IDictionary] $Configuration, [string] $InstancesRoot)
    foreach ($file in Get-ChildItem -LiteralPath $InstancesRoot -Filter config.psd1 -File -Recurse -ErrorAction Stop) {
        if ($file.FullName -eq $Configuration.ConfigPath) { continue }
        $other = Read-DBConfiguration $file.FullName
        if ($other.InstanceName -eq $Configuration.InstanceName) { throw "Duplicate InstanceName: $($other.InstanceName)" }
        foreach ($a in $Configuration.Paths.Values) {
            foreach ($b in $other.Paths.Values) {
                if ((Test-DBPathWithin $a $b) -or (Test-DBPathWithin $b $a)) { throw 'Instances share overlapping state directories.' }
            }
        }
        foreach ($a in @($Configuration.InstanceRoot, $Configuration.SecretsRoot)) {
            foreach ($b in @($other.InstanceRoot, $other.SecretsRoot) + @($other.Paths.Values)) {
                if ((Test-DBPathWithin $a $b) -or (Test-DBPathWithin $b $a)) { throw 'Instances share configuration or secret directories.' }
            }
        }
    }
}

Export-ModuleMember -Function Read-DBConfiguration, Resolve-DBPath, Test-DBPathWithin, Assert-DBIdentifier, Assert-DBInstanceIsolation
