Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../../Core/Process.psm1')

function Assert-MySqlDatabaseArgument {
    param([AllowEmptyCollection()][string[]] $ExtraArguments)

    foreach ($argument in $ExtraArguments) {
        if ($argument -match '^(--password(?:=|$)|-p.+)') {
            throw 'Database.ExtraArguments must not contain a password.'
        }
        if ($argument -match '^--force(?:=|$)') {
            throw 'Database.ExtraArguments must not contain --force; DBBackup controls degraded dumps.'
        }
    }
}

function Invoke-MySqlProcess {
    param([string] $ExecutablePath, [string[]] $Arguments, [string] $OutputPath, [double] $TimeoutSeconds = 21600)
    Invoke-DBTool -Executable $ExecutablePath -Arguments $Arguments -OutputPath $OutputPath -TimeoutSeconds $TimeoutSeconds
}

function Invoke-MySqlDatabaseDump {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $MySqlDumpPath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $DefaultsExtraFile,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $DatabaseName,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $OutputPath,
        [AllowEmptyCollection()][string[]] $ExtraArguments = @(),
        [string] $DatabaseObject,
        [switch] $Force,
        [double] $TimeoutSeconds = 21600
    )

    if (-not (Test-Path -LiteralPath $DefaultsExtraFile -PathType Leaf)) {
        throw "MySQL defaults file was not found: $DefaultsExtraFile"
    }
    Assert-MySqlDatabaseArgument -ExtraArguments $ExtraArguments

    $arguments = @("--defaults-extra-file=$DefaultsExtraFile", '--single-transaction', '--quick')
    if ([string]::IsNullOrWhiteSpace($DatabaseObject)) {
        $arguments += @('--routines', '--events', '--triggers')
        if ($Force) { $arguments += '--force' }
        $arguments += $ExtraArguments
        $arguments += @('--databases', $DatabaseName)
    }
    else {
        $arguments += @('--skip-routines', '--skip-events', '--triggers')
        if ($Force) { $arguments += '--force' }
        $arguments += $ExtraArguments
        $arguments += @($DatabaseName, $DatabaseObject)
    }

    $result = Invoke-MySqlProcess -ExecutablePath $MySqlDumpPath -Arguments $arguments -OutputPath $OutputPath -TimeoutSeconds $TimeoutSeconds
    $length = if ($null -eq $result.File) { 0 } else { $result.File.Length }
    [pscustomobject]@{
        File       = $result.File
        ExitCode   = $result.ExitCode
        StdErr     = $result.StdErr
        IsNonEmpty = $length -gt 0
        Length     = $length
    }
}

function New-MySqlDatabaseDump {
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $MySqlDumpPath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $DefaultsExtraFile,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $DatabaseName,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $OutputPath,
        [AllowEmptyCollection()][string[]] $ExtraArguments = @(),
        [double] $TimeoutSeconds = 21600
    )

    try {
        $result = Invoke-MySqlDatabaseDump @PSBoundParameters
        if ($result.ExitCode -ne 0) {
            throw "mysqldump failed with exit code $($result.ExitCode). $($result.StdErr)"
        }
        if (-not $result.IsNonEmpty) {
            throw "mysqldump created an empty dump: $OutputPath"
        }
        return $result.File
    }
    catch {
        if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
            Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Get-MySqlDatabaseObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $MySqlPath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $DefaultsExtraFile,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $DatabaseName,
        [double] $TimeoutSeconds = 21600
    )

    if (-not (Test-Path -LiteralPath $DefaultsExtraFile -PathType Leaf)) {
        throw "MySQL defaults file was not found: $DefaultsExtraFile"
    }
    $arguments = @(
        "--defaults-extra-file=$DefaultsExtraFile"
        '--batch'
        '--raw'
        '--skip-column-names'
        "--database=$DatabaseName"
        '--execute=SHOW FULL TABLES'
    )
    $result = Invoke-MySqlProcess -ExecutablePath $MySqlPath -Arguments $arguments -TimeoutSeconds $TimeoutSeconds
    if ($result.ExitCode -ne 0) {
        throw "mysql failed to list database objects with exit code $($result.ExitCode). $($result.StdErr)"
    }

    $objects = @()
    foreach ($line in @($result.StdOut -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = @($line -split "`t", 2)
        if ($parts.Count -ne 2 -or $parts[1] -notin @('BASE TABLE', 'VIEW')) {
            throw "mysql returned an invalid SHOW FULL TABLES row: $line"
        }
        $objects += [pscustomobject]@{ Name = $parts[0]; ObjectType = $parts[1] }
    }
    return $objects
}

function Get-MySqlDatabaseSize {
    <# Approximate data+index bytes of the database, used only as a disk estimate. #>
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $MySqlPath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $DefaultsExtraFile,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $DatabaseName,
        [double] $TimeoutSeconds = 300
    )

    $arguments = @(
        "--defaults-extra-file=$DefaultsExtraFile"
        '--batch'
        '--raw'
        '--skip-column-names'
        "--database=$DatabaseName"
        '--execute=SELECT COALESCE(SUM(data_length + index_length), 0) FROM information_schema.tables WHERE table_schema = DATABASE()'
    )
    $result = Invoke-MySqlProcess -ExecutablePath $MySqlPath -Arguments $arguments -TimeoutSeconds $TimeoutSeconds
    if ($result.ExitCode -ne 0) { throw "mysql size query failed with exit code $($result.ExitCode)." }
    [long] $bytes = 0
    $text = ([string] $result.StdOut).Trim()
    if (-not [long]::TryParse($text, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref] $bytes) -or $bytes -lt 0) {
        throw 'mysql size query returned an invalid value.'
    }
    return $bytes
}

function Get-MySqlSafeFileName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Name,
        [System.Collections.IDictionary] $UsedNames
    )

    $safeName = [regex]::Replace($Name, '[\x00-\x1f<>:"/\\|?*]', '_').TrimEnd(' ', '.')
    if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = '_' }
    if ($safeName -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
        $safeName = "_$safeName"
    }

    $requiresHash = $safeName -cne $Name
    if ($null -ne $UsedNames -and $UsedNames.Contains($safeName.ToLowerInvariant())) {
        $requiresHash = $true
    }
    if ($requiresHash) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Name)
        $hash = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).Substring(0, 8).ToLowerInvariant()
        $safeName = "${safeName}_$hash"
    }
    if ($null -ne $UsedNames) { $UsedNames[$safeName.ToLowerInvariant()] = $true }
    return $safeName
}

Export-ModuleMember -Function New-MySqlDatabaseDump, Invoke-MySqlDatabaseDump, Get-MySqlDatabaseObject, Get-MySqlDatabaseSize, Get-MySqlSafeFileName
