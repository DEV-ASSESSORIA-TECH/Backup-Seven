Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Client.psm1')
Import-Module (Join-Path $PSScriptRoot '../../Core/Runtime.psm1')

function Invoke-DBMySql {
    param([Collections.IDictionary] $Configuration, $Job, $Runtime)
    $started = [DateTime]::UtcNow
    $root = Join-Path $Runtime.Work $Job.Id
    $normal = Join-Path $root 'normal'
    $null = New-Item -ItemType Directory -Path $normal -Force
    $argsMap = @{
        MySqlDumpPath = $Configuration.Tools.MySqlDump
        DefaultsExtraFile = $Configuration.Database.DefaultsExtraFile
        DatabaseName = $Configuration.Database.Name
        TimeoutSeconds = if ($Configuration.Contains('Execution')) { $Configuration.Execution.ToolTimeoutSeconds } else { 21600 }
        ExtraArguments = @($Configuration.Database.ExtraArguments)
    }
    # Reject unsafe user arguments before entering any fallback.
    foreach ($argument in $argsMap.ExtraArguments) {
        if ($argument -match '(?i)^(--(?:password|force|result-file|defaults-file|defaults-extra-file|defaults-group-suffix)(?:=|$)|-p|-r)') {
            throw 'Unsafe Database.ExtraArguments option.'
        }
    }
    $errors = @()
    $normalResult = $null
    try {
        $normalResult = Invoke-MySqlDatabaseDump @argsMap -OutputPath (Join-Path $normal 'database.sql')
        if ($normalResult.ExitCode -eq 0 -and $normalResult.IsNonEmpty) {
            return [pscustomobject]@{
                Status = 'SUCCESS'; Packages = @([pscustomobject]@{ Role = 'FULL'; SourcePath = $normal; ContentsOnly = $true })
                Errors = @(); StartedAtUtc = $started; FinishedAtUtc = [DateTime]::UtcNow
                Metadata = @{ Strategy = 'logical-dump'; Database = $Configuration.Database.Name; Validation = 'exit-code-and-nonempty'; ExtraArguments = $argsMap.ExtraArguments }
            }
        }
        $errors += Protect-DBMessage "Normal dump failed (exit $($normalResult.ExitCode)): $($normalResult.StdErr)"
    }
    catch { $errors += Protect-DBMessage $_.Exception.Message }
    if (Test-Path -LiteralPath $normal) { Remove-Item -LiteralPath $normal -Recurse -Force }
    $packages = @()
    $general = Join-Path $root 'general'
    $granular = Join-Path $root 'granular'
    $null = New-Item -ItemType Directory -Path $general, $granular -Force
    $generalInfo = $null
    try {
        $forced = Invoke-MySqlDatabaseDump @argsMap -OutputPath (Join-Path $general 'database.sql') -Force
        $generalInfo = @{ ExitCode = $forced.ExitCode; Error = (Protect-DBMessage $forced.StdErr) }
        if ($forced.IsNonEmpty) { $packages += [pscustomobject]@{ Role = 'GENERAL'; SourcePath = $general; ContentsOnly = $true } }
        else { $errors += 'Forced general dump was empty.' }
    }
    catch { $errors += Protect-DBMessage $_.Exception.Message }
    $objects = @()
    $listingSucceeded = $false
    try {
        $listed = @(Get-MySqlDatabaseObject -MySqlPath $Configuration.Tools.MySql -DefaultsExtraFile $Configuration.Database.DefaultsExtraFile -DatabaseName $Configuration.Database.Name -TimeoutSeconds $argsMap.TimeoutSeconds)
        $usedNames = @{}
        foreach ($object in $listed) {
            $name = Get-MySqlSafeFileName -Name $object.Name -UsedNames $usedNames
            $path = Join-Path $granular "$name.sql"
            try {
                $dump = Invoke-MySqlDatabaseDump @argsMap -OutputPath $path -DatabaseObject $object.Name
                if ($dump.ExitCode -ne 0 -or -not $dump.IsNonEmpty) { throw "Object dump failed (exit $($dump.ExitCode)): $($dump.StdErr)" }
                $objects += @{ Name = $object.Name; Type = $object.ObjectType; Status = 'SUCCESS'; File = "$name.sql" }
            }
            catch {
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
                $message = Protect-DBMessage $_.Exception.Message
                Set-Content -LiteralPath (Join-Path $granular "${name}_FAILED.txt") -Value $message -Encoding utf8
                $objects += @{ Name = $object.Name; Type = $object.ObjectType; Status = 'FAILED'; Error = $message }
            }
        }
        $listingSucceeded = $true
        # An empty enumeration is recorded so the package is never silently empty.
        $objects | ConvertTo-Json -Depth 8 -AsArray | Set-Content (Join-Path $granular 'objects.json') -Encoding utf8
        $packages += [pscustomobject]@{ Role = 'GRANULAR'; SourcePath = $granular; ContentsOnly = $true }
    }
    catch { $errors += Protect-DBMessage $_.Exception.Message }
    [pscustomobject]@{
        Status = if ($packages.Count -eq 2) { 'DEGRADED' } else { 'FAILED' }
        Packages = @($packages); Errors = @($errors); StartedAtUtc = $started; FinishedAtUtc = [DateTime]::UtcNow
        Metadata = @{ Strategy = 'force+granular'; Database = $Configuration.Database.Name; General = $generalInfo; ListingSucceeded = $listingSucceeded; Objects = $objects; ExtraArguments = $argsMap.ExtraArguments }
    }
}
Export-ModuleMember -Function Invoke-DBMySql
