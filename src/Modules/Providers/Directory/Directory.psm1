Set-StrictMode -Version Latest

function Invoke-DBDirectory {
    <#
    No staging copy: the package points at the configured source (ContentPath)
    and the archive step reads it in place under content/. Work only receives
    the manifest. Links are rejected while the manifest is built.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Configuration', Justification = 'Common provider interface.')]
    [CmdletBinding()]
    param([Collections.IDictionary] $Configuration, $Job, $Runtime)
    $started = [DateTime]::UtcNow
    if (-not (Test-Path -LiteralPath $Job.SourcePath -PathType Container)) { throw 'Directory source was not found.' }
    if ((Get-Item -LiteralPath $Job.SourcePath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Directory source cannot be a link.' }
    $root = Join-Path $Runtime.Work $Job.Id
    $null = New-Item -ItemType Directory -Path $root -Force
    [pscustomobject]@{
        Status = 'SUCCESS'
        Packages = @([pscustomobject]@{ Role = 'FULL'; SourcePath = $root; ContentPath = $Job.SourcePath; ContentsOnly = $true })
        Errors = @(); StartedAtUtc = $started; FinishedAtUtc = [DateTime]::UtcNow
        Metadata = @{ Strategy = 'directory-archive-in-place'; Validation = 'archive-test'; Consistency = 'live-files-no-snapshot' }
    }
}
Export-ModuleMember -Function Invoke-DBDirectory
