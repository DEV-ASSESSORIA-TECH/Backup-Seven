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
Export-ModuleMember -Function Assert-DBFreeSpace, Get-DBDirectorySize
