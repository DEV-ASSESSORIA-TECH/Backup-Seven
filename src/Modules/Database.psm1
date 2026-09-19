Set-StrictMode -Version Latest

function Assert-SevenDatabaseArguments {
    param([string[]] $ExtraArguments)

    foreach ($argument in $ExtraArguments) {
        if ($argument -match '^(--password(?:=|$)|-p.+)') {
            throw 'Database.ExtraArguments must not contain a password.'
        }
        if ($argument -match '^--force(?:=|$)') {
            throw 'Database.ExtraArguments must not contain --force; BackupSeven controls degraded dumps.'
        }
    }
}

function Invoke-SevenProcess {
    param(
        [Parameter(Mandatory)][string] $ExecutablePath,
        [Parameter(Mandatory)][string[]] $Arguments,
        [string] $OutputPath
    )

    if (-not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) {
        throw "Executable was not found: $ExecutablePath"
    }

    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        if (Test-Path -LiteralPath $OutputPath) {
            throw "Database dump destination already exists: $OutputPath"
        }
        $outputDirectory = Split-Path -Parent $OutputPath
        if ([string]::IsNullOrWhiteSpace($outputDirectory)) {
            throw 'Database dump path must include a parent directory.'
        }
        $null = New-Item -ItemType Directory -Path $outputDirectory -Force
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $ExecutablePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        $null = $startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $outputStream = $null
    try {
        if (-not $process.Start()) {
            throw 'Database process could not be started.'
        }

        $stderrTask = $process.StandardError.ReadToEndAsync()
        $standardOutput = $null
        if ([string]::IsNullOrWhiteSpace($OutputPath)) {
            $standardOutput = $process.StandardOutput.ReadToEnd()
        }
        else {
            $outputStream = [System.IO.File]::Create($OutputPath)
            $process.StandardOutput.BaseStream.CopyTo($outputStream)
            $outputStream.Dispose()
            $outputStream = $null
        }

        $process.WaitForExit()
        [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdErr   = $stderrTask.GetAwaiter().GetResult().Trim()
            StdOut   = $standardOutput
            File     = if ([string]::IsNullOrWhiteSpace($OutputPath) -or -not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
                $null
            }
            else {
                Get-Item -LiteralPath $OutputPath
            }
        }
    }
    finally {
        if ($null -ne $outputStream) {
            $outputStream.Dispose()
        }
        $process.Dispose()
    }
}

function Invoke-SevenDatabaseDump {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $MySqlDumpPath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $DefaultsExtraFile,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $DatabaseName,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $OutputPath,
        [string[]] $ExtraArguments = @(),
        [string] $DatabaseObject,
        [switch] $Force
    )

    if (-not (Test-Path -LiteralPath $DefaultsExtraFile -PathType Leaf)) {
        throw "MySQL defaults file was not found: $DefaultsExtraFile"
    }
    Assert-SevenDatabaseArguments -ExtraArguments $ExtraArguments

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

    $result = Invoke-SevenProcess -ExecutablePath $MySqlDumpPath -Arguments $arguments -OutputPath $OutputPath
    $length = if ($null -eq $result.File) { 0 } else { $result.File.Length }
    [pscustomobject]@{
        File       = $result.File
        ExitCode   = $result.ExitCode
        StdErr     = $result.StdErr
        IsNonEmpty = $length -gt 0
        Length     = $length
    }
}

function New-SevenDatabaseDump {
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $MySqlDumpPath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $DefaultsExtraFile,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $DatabaseName,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $OutputPath,
        [string[]] $ExtraArguments = @()
    )

    try {
        $result = Invoke-SevenDatabaseDump @PSBoundParameters
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

function Get-SevenDatabaseObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $MySqlPath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $DefaultsExtraFile,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $DatabaseName
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
    $result = Invoke-SevenProcess -ExecutablePath $MySqlPath -Arguments $arguments
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

function Get-SevenSafeFileName {
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

Export-ModuleMember -Function New-SevenDatabaseDump, Invoke-SevenDatabaseDump, Get-SevenDatabaseObject, Get-SevenSafeFileName
