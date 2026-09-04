Set-StrictMode -Version Latest

$script:LogFilePath = $null
$script:RunId = $null
$script:Mode = $null

function Initialize-BackupLog {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $LogRoot,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $InstanceName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $RunId,

        [Parameter(Mandatory)]
        [ValidateSet('Database', 'Fiscal', 'Full')]
        [string] $Mode,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Version
    )

    $now = [DateTime]::UtcNow
    $null = New-Item -ItemType Directory -Path $LogRoot -Force

    $safeRunId = $RunId -replace '[^A-Za-z0-9_-]', '_'
    $shortRunId = $safeRunId.Substring(0, 8)
    $fileName = 'BackupSevenLog_{0}_{1}Z_{2}_{3}_{4}.log' -f `
        $now.ToString('yyyy-MM-dd'),
        $now.ToString('HHmmss'),
        $InstanceName,
        $Mode,
        $shortRunId

    $script:LogFilePath = Join-Path $LogRoot $fileName
    $script:RunId = $RunId
    $script:Mode = $Mode

    [System.IO.File]::AppendAllText(
        $script:LogFilePath,
        '',
        [System.Text.UTF8Encoding]::new($false)
    )

    Write-BackupLog -Level INFO -Stage 'Startup' -Message "BackupSeven $Version started in $Mode mode."
    return $script:LogFilePath
}

function Write-BackupLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string] $Level,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Stage,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Message
    )

    if ([string]::IsNullOrWhiteSpace($script:LogFilePath)) {
        throw 'The backup log has not been initialized.'
    }

    # Keep one physical line per event so logs remain easy to search and parse.
    $singleLineMessage = $Message -replace '[\r\n]+', ' '
    $timestamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
    $line = '{0} [{1}] [{2}] [{3}/{4}] {5}' -f `
        $timestamp,
        $Level,
        $script:RunId,
        $script:Mode,
        $Stage,
        $singleLineMessage

    [System.IO.File]::AppendAllText(
        $script:LogFilePath,
        $line + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )

    Write-Information $line -InformationAction Continue
}

function Get-BackupLogPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return $script:LogFilePath
}

Export-ModuleMember -Function Initialize-BackupLog, Write-BackupLog, Get-BackupLogPath
