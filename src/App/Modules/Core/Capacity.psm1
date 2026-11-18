Set-StrictMode -Version Latest

function Get-DBAvailableSpace {
    param([string] $Path)
    $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))
    return [IO.DriveInfo]::new($root).AvailableFreeSpace
}

function Assert-DBFreeSpace {
    param([string] $Path, [long] $RequiredBytes, [long] $ReserveBytes = 1073741824)
    if ($RequiredBytes -lt 0 -or $ReserveBytes -lt 0) { throw 'Disk estimates cannot be negative.' }
    $available = Get-DBAvailableSpace $Path
    if ($available -lt ([decimal] $RequiredBytes + $ReserveBytes)) { throw "Insufficient free space: need $RequiredBytes bytes plus $ReserveBytes reserve; available $available." }
}

function Get-DBDirectorySize {
    param([string] $Path)
    [long] $size = 0
    foreach ($item in Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Cannot estimate a directory containing links.' }
        if (-not $item.PSIsContainer) { $size += $item.Length }
    }
    return $size
}
function Get-DBCapacityHistoryPath {
    param([Collections.IDictionary] $Configuration, [string] $Job)
    return Join-Path (Join-Path $Configuration.Paths.RuntimeRoot 'Capacity') "$Job.json"
}

function Read-DBCapacityHistory {
    <# Uncompressed payload bytes of the last complete (SUCCESS) result of a job, or $null. #>
    param([Collections.IDictionary] $Configuration, [string] $Job)
    $path = Get-DBCapacityHistoryPath $Configuration $Job
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $state = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
    if ($state.SchemaVersion -ne 1 -or $state.Instance -cne $Configuration.InstanceName -or $state.Job -cne $Job) { throw 'Capacity history ownership mismatch.' }
    [long] $bytes = 0
    if (-not [long]::TryParse([string] $state.PayloadBytes, [ref] $bytes) -or $bytes -lt 0) { throw 'Invalid capacity history.' }
    return $bytes
}

function Save-DBCapacityHistory {
    param([Collections.IDictionary] $Configuration, [string] $Job, [long] $PayloadBytes)
    $path = Get-DBCapacityHistoryPath $Configuration $Job
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
    $temp = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        @{ SchemaVersion = 1; Instance = $Configuration.InstanceName; Job = $Job; PayloadBytes = $PayloadBytes; UpdatedAtUtc = [DateTime]::UtcNow.ToString('o') } |
            ConvertTo-Json | Set-Content -LiteralPath $temp -Encoding utf8 -ErrorAction Stop
        [IO.File]::Move($temp, $path, $true)
    }
    finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}

function Get-DBJobSpaceEstimate {
    <#
    Bytes the provider is expected to write to Work. Order: directory size;
    explicit Execution.EstimatedDatabaseBytes; last complete payload of this job
    plus 25% growth; otherwise Source = 'unknown' so the caller can try a
    provider probe and the run log makes a missing estimate visible.
    #>
    param([Collections.IDictionary] $Configuration, $Job)
    if ($Job.Provider -eq 'Directory') { return [pscustomobject]@{ Bytes = (Get-DBDirectorySize $Job.SourcePath); Source = 'directory-size'; Warning = $null } }
    $configured = [long] $Configuration.Execution.EstimatedDatabaseBytes
    if ($configured -gt 0) { return [pscustomobject]@{ Bytes = $configured; Source = 'configured'; Warning = $null } }
    $warning = $null
    try {
        $history = Read-DBCapacityHistory $Configuration $Job.Id
        if ($null -ne $history -and $history -gt 0) { return [pscustomobject]@{ Bytes = [long] ([decimal] $history * 1.25); Source = 'last-payload+25%'; Warning = $null } }
    }
    catch { $warning = "Capacity history ignored: $($_.Exception.Message)" }
    return [pscustomobject]@{ Bytes = [long] 0; Source = 'unknown'; Warning = $warning }
}

Export-ModuleMember -Function Assert-DBFreeSpace, Get-DBDirectorySize, Read-DBCapacityHistory, Save-DBCapacityHistory, Get-DBJobSpaceEstimate
