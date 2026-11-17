Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Process.psm1')

function Read-DBRecipients {
    param([string] $Path)
    $recipients = @()
    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction Stop) {
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        if ($line -cnotmatch '^age1[023456789acdefghjklmnpqrstuvwxyz]{58}$') { throw 'Recipients file must contain native age public recipients only.' }
        $recipients += $line
    }
    if ($recipients.Count -eq 0) { throw 'At least one age recipient is required.' }
    return @($recipients | Select-Object -Unique)
}

function Protect-DBArchive {
    param([string] $AgePath, [string] $InputPath, [string] $OutputPath, [string] $RecipientsFile)
    $recipients = @(Read-DBRecipients $RecipientsFile)
    if (Test-Path -LiteralPath $OutputPath) { throw 'Encrypted destination already exists.' }
    $arguments = @('--encrypt', '--output', $OutputPath)
    # Pass the validated snapshot, not a file that could change after validation.
    foreach ($recipient in $recipients) { $arguments += @('--recipient', $recipient) }
    $arguments += $InputPath
    try {
        $result = Invoke-DBTool -Executable $AgePath -Arguments $arguments
        if ($result.ExitCode -ne 0) { throw "age encryption failed (exit $($result.ExitCode))." }
        if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf) -or (Get-Item -LiteralPath $OutputPath).Length -eq 0) { throw 'age did not produce a non-empty file.' }
    }
    catch {
        if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }
        throw
    }
}
Export-ModuleMember -Function Read-DBRecipients, Protect-DBArchive
