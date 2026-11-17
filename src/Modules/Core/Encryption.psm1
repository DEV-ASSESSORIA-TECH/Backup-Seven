Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Process.psm1')

function Get-DBRecipientList {
    <# Validated, de-duplicated native age public recipients from text lines. #>
    param([AllowEmptyCollection()][AllowNull()][string[]] $Lines)
    $recipients = @()
    foreach ($line in @($Lines)) {
        if ($null -eq $line) { continue }
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        if ($line -cnotmatch '^age1[023456789acdefghjklmnpqrstuvwxyz]{58}$') { throw 'Recipients file must contain native age public recipients only.' }
        $recipients += $line
    }
    if ($recipients.Count -eq 0) { throw 'At least one age recipient is required.' }
    return @($recipients | Select-Object -Unique)
}

function Read-DBRecipient {
    param([string] $Path)
    return @(Get-DBRecipientList @(Get-Content -LiteralPath $Path -ErrorAction Stop))
}

function Protect-DBArchive {
    param([string] $AgePath, [string] $InputPath, [string] $OutputPath, [string] $RecipientsFile, [double] $TimeoutSeconds = 21600)
    $recipients = @(Read-DBRecipient $RecipientsFile)
    if (Test-Path -LiteralPath $OutputPath) { throw 'Encrypted destination already exists.' }
    $arguments = @('--encrypt', '--output', $OutputPath)
    # Pass the validated snapshot, not a file that could change after validation.
    foreach ($recipient in $recipients) { $arguments += @('--recipient', $recipient) }
    $arguments += $InputPath
    try {
        $result = Invoke-DBTool -Executable $AgePath -Arguments $arguments -TimeoutSeconds $TimeoutSeconds
        if ($result.ExitCode -ne 0) { throw "age encryption failed (exit $($result.ExitCode))." }
        if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf) -or (Get-Item -LiteralPath $OutputPath).Length -eq 0) { throw 'age did not produce a non-empty file.' }
    }
    catch {
        if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }
        throw
    }
}
Export-ModuleMember -Function Get-DBRecipientList, Read-DBRecipient, Protect-DBArchive
