Set-StrictMode -Version Latest

# Generic backup state for the Grafana Alloy textfile reader (job
# integrations/backup). Metric names, HELP and TYPE follow the
# contracts/prometheus/backup.yml contract of the grafana repository verbatim:
# a different HELP for the same metric in another file is silently dropped by
# the reader.
$script:MetricHelp = [ordered]@{
    backup_last_success_timestamp_seconds  = 'Ponto de recuperacao do ultimo backup concluido e validado (Unix; 0 = nunca).'
    backup_last_success_size_bytes         = 'Tamanho do ultimo backup concluido e validado.'
    backup_last_attempt_timestamp_seconds  = 'Fim da ultima tentativa de backup (Unix).'
    backup_last_attempt_success            = 'Resultado da ultima tentativa de backup (1 = sucesso, 0 = falha).'
    backup_last_attempt_duration_seconds   = 'Duracao da ultima tentativa de backup.'
    backup_last_attempt_degraded           = 'Ultima tentativa publicou um backup degradado (1 = sim, 0 = nao).'
    backup_expected_interval_seconds       = 'Intervalo esperado entre backups bem-sucedidos.'
    backup_collection_timestamp_seconds    = 'Momento em que o produtor gerou este arquivo (Unix).'
    backup_collection_success              = 'Produtor conseguiu observar o estado do backup (1 = sim, 0 = nao).'
    backup_info                            = 'Descricao do backup (valor sempre 1).'
}

$script:IdentifierPattern = '^[a-z0-9]+([-_][a-z0-9]+)*$'

function Test-SevenMetricIdentifier {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][string] $Value)

    return (-not [string]::IsNullOrEmpty($Value)) -and ($Value -cmatch $script:IdentifierPattern)
}

function ConvertTo-SevenLabelValue {
    param([AllowNull()][string] $Value)

    if ($null -eq $Value) { return '' }
    return $Value.Replace('\', '\\').Replace('"', '\"').Replace("`r", '').Replace("`n", '\n')
}

function ConvertTo-SevenMetricNumber {
    param([Parameter(Mandatory)][double] $Value)

    return $Value.ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-SevenUnixSecond {
    param([Parameter(Mandatory)][DateTime] $Value)

    return [long] [Math]::Floor(([DateTimeOffset] $Value.ToUniversalTime()).ToUnixTimeMilliseconds() / 1000)
}

function Get-SevenBackupMetricFileName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $Service,
        [Parameter(Mandatory)][string] $BackupId
    )

    return '{0}__{1}.prom' -f $Service, $BackupId
}

function Read-SevenBackupMetricState {
    <#
    Reads the last known success from a previously written file, so a success
    that already left the local retention window keeps being reported.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string] $Path)

    $state = [pscustomobject]@{ LastSuccessTimestamp = [long] 0; LastSuccessSizeBytes = $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $state
    }

    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line -match '^backup_last_success_timestamp_seconds\{[^}]*\}\s+(?<value>\d+)\s*$') {
            $state.LastSuccessTimestamp = [long] $Matches.value
        }
        elseif ($line -match '^backup_last_success_size_bytes\{[^}]*\}\s+(?<value>\d+)\s*$') {
            $state.LastSuccessSizeBytes = [long] $Matches.value
        }
    }

    return $state
}

function Format-SevenBackupMetric {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $Service,
        [Parameter(Mandatory)][string] $BackupId,
        [Parameter(Mandatory)][DateTime] $CollectedAtUtc,
        [Parameter(Mandatory)][bool] $CollectionSucceeded,
        [Nullable[DateTime]] $AttemptFinishedAtUtc,
        [Nullable[bool]] $AttemptSucceeded,
        [Nullable[bool]] $AttemptDegraded,
        [Nullable[double]] $AttemptDurationSeconds,
        [long] $LastSuccessTimestamp = 0,
        [Nullable[long]] $LastSuccessSizeBytes,
        [Nullable[double]] $ExpectedIntervalSeconds,
        [System.Collections.IDictionary] $InfoLabels = @{}
    )

    if (-not (Test-SevenMetricIdentifier -Value $Service)) { throw "Invalid backup service identifier: '$Service'." }
    if (-not (Test-SevenMetricIdentifier -Value $BackupId)) { throw "Invalid backup identifier: '$BackupId'." }

    $identity = 'service="{0}",backup_id="{1}"' -f $Service, $BackupId
    $samples = [ordered]@{}
    $samples.backup_info = $null
    $samples.backup_collection_timestamp_seconds = [string] (ConvertTo-SevenUnixSecond -Value $CollectedAtUtc)
    $samples.backup_collection_success = if ($CollectionSucceeded) { '1' } else { '0' }

    if ($CollectionSucceeded) {
        $samples.backup_last_success_timestamp_seconds = [string] $LastSuccessTimestamp
        if ($LastSuccessTimestamp -gt 0 -and $null -ne $LastSuccessSizeBytes) {
            $samples.backup_last_success_size_bytes = [string] $LastSuccessSizeBytes
        }
    }

    if ($null -ne $AttemptFinishedAtUtc) {
        $samples.backup_last_attempt_timestamp_seconds = [string] (ConvertTo-SevenUnixSecond -Value $AttemptFinishedAtUtc)
        if ($null -ne $AttemptSucceeded) {
            $samples.backup_last_attempt_success = if ($AttemptSucceeded) { '1' } else { '0' }
        }
        if ($null -ne $AttemptDurationSeconds) {
            $samples.backup_last_attempt_duration_seconds = ConvertTo-SevenMetricNumber -Value ([Math]::Max([double] 0, [double] $AttemptDurationSeconds))
        }
        if ($null -ne $AttemptDegraded) {
            $samples.backup_last_attempt_degraded = if ($AttemptDegraded) { '1' } else { '0' }
        }
    }

    if ($null -ne $ExpectedIntervalSeconds -and $ExpectedIntervalSeconds -gt 0) {
        $samples.backup_expected_interval_seconds = ConvertTo-SevenMetricNumber -Value $ExpectedIntervalSeconds
    }

    $builder = [System.Text.StringBuilder]::new()
    foreach ($name in $script:MetricHelp.Keys) {
        if (-not $samples.Contains($name)) { continue }

        $null = $builder.Append("# HELP $name $($script:MetricHelp[$name])`n")
        $null = $builder.Append("# TYPE $name gauge`n")
        if ($name -eq 'backup_info') {
            $labels = [System.Collections.Generic.List[string]]::new()
            $labels.Add($identity)
            foreach ($key in @($InfoLabels.Keys | Sort-Object)) {
                if ($key -in @('service', 'backup_id', 'job', 'instance', 'host') -or $key -notmatch '^[a-z_][a-z0-9_]*$') {
                    throw "Invalid backup_info label: '$key'."
                }
                $labels.Add(('{0}="{1}"' -f $key, (ConvertTo-SevenLabelValue -Value ([string] $InfoLabels[$key]))))
            }
            $null = $builder.Append("$name{$($labels -join ',')} 1`n")
        }
        else {
            $null = $builder.Append("$name{$identity} $($samples[$name])`n")
        }
    }

    return $builder.ToString()
}

function Write-SevenBackupMetric {
    <#
    Writes <Service>__<BackupId>.prom atomically: UTF-8 without BOM, LF line
    endings, a final newline and a .prom.tmp sibling that the reader ignores.
    The directory belongs to the Alloy installation and is never created here.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $Directory,
        [Parameter(Mandatory)][string] $Service,
        [Parameter(Mandatory)][string] $BackupId,
        [Parameter(Mandatory)][string] $Content
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        throw "Monitoring textfile directory was not found: $Directory"
    }

    $path = Join-Path $Directory (Get-SevenBackupMetricFileName -Service $Service -BackupId $BackupId)
    $temporaryPath = "$path.tmp"
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $Content, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($temporaryPath, $path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }

    return $path
}

Export-ModuleMember -Function Test-SevenMetricIdentifier, Get-SevenBackupMetricFileName, Read-SevenBackupMetricState, Format-SevenBackupMetric, Write-SevenBackupMetric
