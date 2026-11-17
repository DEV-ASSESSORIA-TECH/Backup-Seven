Set-StrictMode -Version Latest

function Copy-DBDirectoryContent {
    param([string] $Source, [string] $Destination)
    $null = New-Item -ItemType Directory -Path $Destination -Force
    foreach ($item in Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked directory content is not supported: $($item.FullName)" }
        $target = Join-Path $Destination $item.Name
        if ($item.PSIsContainer) { Copy-DBDirectoryContent $item.FullName $target }
        else { Copy-Item -LiteralPath $item.FullName -Destination $target -ErrorAction Stop }
    }
}

function Invoke-DBDirectory {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Configuration', Justification = 'Common provider interface.')]
    [CmdletBinding()]
    param([Collections.IDictionary] $Configuration, $Job, $Runtime)
    $started = [DateTime]::UtcNow
    if (-not (Test-Path -LiteralPath $Job.SourcePath -PathType Container)) { throw 'Directory source was not found.' }
    if ((Get-Item -LiteralPath $Job.SourcePath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Directory source cannot be a link.' }
    $root = Join-Path $Runtime.Work $Job.Id
    Copy-DBDirectoryContent $Job.SourcePath (Join-Path $root 'content')
    [pscustomobject]@{
        Status = 'SUCCESS'; Packages = @([pscustomobject]@{ Role = 'FULL'; SourcePath = $root; ContentsOnly = $true })
        Errors = @(); StartedAtUtc = $started; FinishedAtUtc = [DateTime]::UtcNow
        Metadata = @{ Strategy = 'directory-copy'; Validation = 'copy-completed'; Consistency = 'live-files-no-snapshot' }
    }
}
Export-ModuleMember -Function Invoke-DBDirectory
