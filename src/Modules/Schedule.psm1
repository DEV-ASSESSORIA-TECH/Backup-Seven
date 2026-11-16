Set-StrictMode -Version Latest

# Agendamentos declarados em config.psd1 (secao Schedule). O modulo so le,
# valida e descreve; quem registra as tarefas no Windows e o
# Setup-BackupSeven.ps1 (-Apply).

$script:TaskFolder = '\BackupSeven\'
# SYSTEM e Administradores com acesso total; usuarios comuns nao veem as
# tarefas nem a pasta.
$script:TaskSecurity = 'D:P(A;;FA;;;SY)(A;;FA;;;BA)'
$script:DayNames = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')
$script:MonthNames = @('January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December')

function Get-SevenScheduleTaskFolder {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return $script:TaskFolder
}

function Get-SevenScheduleTaskSecurity {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return $script:TaskSecurity
}

function Test-SevenScheduleSection {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Configuration)

    return $Configuration.Contains('Schedule') -and $null -ne $Configuration.Schedule
}

function Get-SevenScheduleTask {
    <#
    Normaliza Schedule.Tasks. Cada item pode ser so o horario ('19:00' = Full,
    diario) ou um hashtable com At e, opcionalmente, Mode (Full, Database,
    Fiscal), Frequency (Daily, Weekly, Monthly), Days (Weekly, em ingles),
    DaysOfMonth (Monthly: 1-31 ou 'Last'), Name e Enabled.
    Sem a secao Schedule, devolve uma lista vazia. Erro de validacao lanca
    excecao com a posicao do item.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Configuration)

    if (-not (Test-SevenScheduleSection -Configuration $Configuration)) {
        return @()
    }

    $section = $Configuration.Schedule
    if ($section -isnot [System.Collections.IDictionary]) {
        throw "Configuration section 'Schedule' must be a hashtable."
    }
    if (-not $section.Contains('Tasks') -or $null -eq $section.Tasks) {
        return @()
    }

    $tasks = [System.Collections.Generic.List[object]]::new()
    $names = @{}
    $index = 0
    foreach ($item in @($section.Tasks)) {
        $index++
        $where = "Schedule.Tasks[$index]"
        $entry = if ($item -is [System.Collections.IDictionary]) { $item } elseif ($item -is [string]) { @{ At = $item } } else { $null }
        if ($null -eq $entry) {
            throw "$where must be a time ('19:00') or a hashtable."
        }

        foreach ($key in @($entry.Keys)) {
            if ($key -notin @('Name', 'Mode', 'Frequency', 'At', 'Days', 'DaysOfMonth', 'Enabled')) {
                throw "$where has an unknown key: $key"
            }
        }

        $at = [string] $entry['At']
        if ($at -notmatch '^([01]\d|2[0-3]):[0-5]\d$') {
            throw "$where.At must use HH:mm (24h): '$at'"
        }

        $mode = 'Full'
        if ($entry.Contains('Mode') -and $null -ne $entry.Mode) {
            $mode = @('Full', 'Database', 'Fiscal') | Where-Object { $_ -eq [string] $entry.Mode } | Select-Object -First 1
            if (-not $mode) { throw "$where.Mode must be Full, Database or Fiscal: '$($entry.Mode)'" }
        }

        $frequency = 'Daily'
        if ($entry.Contains('Frequency') -and $null -ne $entry.Frequency) {
            $frequency = @('Daily', 'Weekly', 'Monthly') | Where-Object { $_ -eq [string] $entry.Frequency } | Select-Object -First 1
            if (-not $frequency) { throw "$where.Frequency must be Daily, Weekly or Monthly: '$($entry.Frequency)'" }
        }

        $days = @()
        $daysOfMonth = @()
        if ($frequency -eq 'Weekly') {
            if (-not $entry.Contains('Days') -or @($entry.Days).Count -eq 0) {
                throw "$where.Days is required for Weekly (Monday ... Sunday)."
            }
            foreach ($day in @($entry.Days)) {
                $name = $script:DayNames | Where-Object { $_ -eq [string] $day } | Select-Object -First 1
                if (-not $name) { throw "$where.Days has an invalid day: '$day' (use Monday ... Sunday)." }
                if ($name -notin $days) { $days += $name }
            }
            $days = @($script:DayNames | Where-Object { $_ -in $days })
        }
        elseif ($entry.Contains('Days')) {
            throw "$where.Days is only valid with Frequency = 'Weekly'."
        }

        if ($frequency -eq 'Monthly') {
            if (-not $entry.Contains('DaysOfMonth') -or @($entry.DaysOfMonth).Count -eq 0) {
                throw "$where.DaysOfMonth is required for Monthly (1-31 or 'Last')."
            }
            foreach ($day in @($entry.DaysOfMonth)) {
                $value = [string] $day
                if ($value -eq 'Last') { $value = 'Last' }
                elseif ($value -match '^\d+$' -and [int] $value -ge 1 -and [int] $value -le 31) { $value = [string] [int] $value }
                else { throw "$where.DaysOfMonth has an invalid day: '$day' (use 1-31 or 'Last')." }
                if ($value -notin $daysOfMonth) { $daysOfMonth += $value }
            }
        }
        elseif ($entry.Contains('DaysOfMonth')) {
            throw "$where.DaysOfMonth is only valid with Frequency = 'Monthly'."
        }

        $enabled = $true
        if ($entry.Contains('Enabled') -and $null -ne $entry.Enabled) {
            if ($entry.Enabled -isnot [bool]) { throw "$where.Enabled must be `$true or `$false." }
            $enabled = $entry.Enabled
        }

        $name = if ($entry.Contains('Name') -and -not [string]::IsNullOrWhiteSpace([string] $entry.Name)) {
            ([string] $entry.Name).Trim()
        }
        else {
            '{0} {1} {2}' -f $mode, $frequency, $at.Replace(':', 'h')
        }
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9 _-]*$') {
            throw "$where.Name may contain only letters, numbers, spaces, '-' and '_': '$name'"
        }
        if ($names.ContainsKey($name.ToLowerInvariant())) {
            throw "$where.Name '$name' is repeated; give each task its own Name."
        }
        $names[$name.ToLowerInvariant()] = $true

        $tasks.Add([pscustomobject]@{
                Name        = $name
                Mode        = $mode
                Frequency   = $frequency
                At          = $at
                Days        = $days
                DaysOfMonth = $daysOfMonth
                Enabled     = $enabled
            })
    }

    return $tasks.ToArray()
}

function Test-SevenScheduleRunsOn {
    param(
        [Parameter(Mandatory)][pscustomobject] $Task,
        [Parameter(Mandatory)][DateTime] $Date
    )

    switch ($Task.Frequency) {
        'Daily' { return $true }
        'Weekly' { return ([string] $Date.DayOfWeek) -in $Task.Days }
        'Monthly' {
            $last = [DateTime]::DaysInMonth($Date.Year, $Date.Month)
            return ([string] $Date.Day) -in $Task.DaysOfMonth -or ($Date.Day -eq $last -and 'Last' -in $Task.DaysOfMonth)
        }
    }
    return $false
}

function Get-SevenScheduleMaxGap {
    <#
    Maior intervalo, em horas, entre execucoes ativas que cobrem o tipo (Full
    cobre Database e Fiscal). Calculado sobre um ano de calendario simulado.
    Devolve $null quando nenhuma tarefa ativa cobre o tipo.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Tasks,
        [Parameter(Mandatory)][ValidateSet('Database', 'Fiscal')][string] $BackupType
    )

    $covering = @($Tasks | Where-Object { $_.Enabled -and $_.Mode -in @('Full', $BackupType) })
    if ($covering.Count -eq 0) { return $null }

    $start = [DateTime]::new(2026, 1, 1)
    $runs = [System.Collections.Generic.List[DateTime]]::new()
    for ($offset = 0; $offset -lt 400; $offset++) {
        $date = $start.AddDays($offset)
        foreach ($task in $covering) {
            if (Test-SevenScheduleRunsOn -Task $task -Date $date) {
                $runs.Add($date.Add([TimeSpan]::Parse($task.At, [System.Globalization.CultureInfo]::InvariantCulture)))
            }
        }
    }

    $sorted = @($runs | Sort-Object -Unique)
    if ($sorted.Count -lt 2) { return $null }
    $max = 0.0
    for ($i = 1; $i -lt $sorted.Count; $i++) {
        $gap = ($sorted[$i] - $sorted[$i - 1]).TotalHours
        if ($gap -gt $max) { $max = $gap }
    }
    return $max
}

function Get-SevenScheduleNextRun {
    <#
    Primeira execucao ativa que cobre o tipo (Full cobre Database e Fiscal)
    estritamente depois de -After, no horario local do servidor (o mesmo das
    tarefas agendadas). Devolve $null quando nenhuma tarefa ativa cobre o tipo.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Tasks,
        [Parameter(Mandatory)][ValidateSet('Database', 'Fiscal')][string] $BackupType,
        [Parameter(Mandatory)][DateTime] $After
    )

    $covering = @($Tasks | Where-Object { $_.Enabled -and $_.Mode -in @('Full', $BackupType) })
    if ($covering.Count -eq 0) { return $null }

    $next = $null
    for ($offset = 0; $offset -lt 400 -and $null -eq $next; $offset++) {
        $date = $After.Date.AddDays($offset)
        foreach ($task in $covering) {
            if (-not (Test-SevenScheduleRunsOn -Task $task -Date $date)) { continue }
            $run = $date.Add([TimeSpan]::Parse($task.At, [System.Globalization.CultureInfo]::InvariantCulture))
            if ($run -gt $After -and ($null -eq $next -or $run -lt $next)) { $next = $run }
        }
    }
    return $next
}

function Get-SevenScheduleWarning {
    <#
    Avisos que nao impedem a aplicacao: tarefas ativas no mesmo horario, que
    competem pelo lock (a segunda termina com exit code 3 sem fazer backup).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Tasks)

    $warnings = @()
    foreach ($group in @($Tasks | Where-Object Enabled | Group-Object At | Where-Object Count -gt 1)) {
        $warnings += "Tarefas no mesmo horario ($($group.Name)): $(($group.Group.Name) -join ', '). So uma roda; as outras terminam com exit code 3."
    }
    return $warnings
}

function ConvertTo-SevenXmlText {
    param([AllowNull()][string] $Value)
    return [System.Security.SecurityElement]::Escape([string] $Value)
}

function Get-SevenTaskDefinition {
    <#
    XML de registro da tarefa (Register-ScheduledTask -Xml), executada como
    SYSTEM com -ExecutionPolicy Bypass. Description leva uma impressao digital
    da definicao ([cfg:...]) para detectar mudancas na configuracao.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject] $Task,
        [Parameter(Mandatory)][string] $PwshPath,
        [Parameter(Mandatory)][string] $ScriptPath,
        [Parameter(Mandatory)][string] $WorkingDirectory
    )

    $arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`" -Mode $($Task.Mode)"
    $schedule = switch ($Task.Frequency) {
        'Daily' { '<ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay>' }
        'Weekly' {
            '<ScheduleByWeek><WeeksInterval>1</WeeksInterval><DaysOfWeek>' +
            (($Task.Days | ForEach-Object { "<$_ />" }) -join '') + '</DaysOfWeek></ScheduleByWeek>'
        }
        'Monthly' {
            '<ScheduleByMonth><DaysOfMonth>' + (($Task.DaysOfMonth | ForEach-Object { "<Day>$_</Day>" }) -join '') +
            '</DaysOfMonth><Months>' + (($script:MonthNames | ForEach-Object { "<$_ />" }) -join '') + '</Months></ScheduleByMonth>'
        }
    }
    $enabled = if ($Task.Enabled) { 'true' } else { 'false' }

    $body = @"
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>2026-01-01T$($Task.At):00</StartBoundary>
      <Enabled>true</Enabled>
      $schedule
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>$enabled</Enabled>
    <ExecutionTimeLimit>PT12H</ExecutionTimeLimit>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$(ConvertTo-SevenXmlText $PwshPath)</Command>
      <Arguments>$(ConvertTo-SevenXmlText $arguments)</Arguments>
      <WorkingDirectory>$(ConvertTo-SevenXmlText $WorkingDirectory)</WorkingDirectory>
    </Exec>
  </Actions>
"@
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($body)) | Select-Object -First 6 | ForEach-Object { $_.ToString('x2') })
    }
    finally {
        $sha.Dispose()
    }

    $description = "Gerenciada pelo BackupSeven (config.psd1, secao Schedule). Alteracoes feitas aqui sao desfeitas ao aplicar a configuracao. [cfg:$hash]"
    $xml = @"
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>$(ConvertTo-SevenXmlText $description)</Description>
    <SecurityDescriptor>$($script:TaskSecurity)</SecurityDescriptor>
  </RegistrationInfo>
$body
</Task>
"@
    [pscustomobject]@{
        Name      = $Task.Name
        Hash      = $hash
        Xml       = $xml.Replace("`r`n", "`n")
        Arguments = $arguments
    }
}

function Get-SevenTaskDefinitionHash {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string] $Description)

    if ($Description -match '\[cfg:([0-9a-f]{12})\]') { return $Matches[1] }
    return $null
}

Export-ModuleMember -Function Get-SevenScheduleTaskFolder, Get-SevenScheduleTaskSecurity, Test-SevenScheduleSection, Get-SevenScheduleTask, Get-SevenScheduleMaxGap, Get-SevenScheduleNextRun, Get-SevenScheduleWarning, Get-SevenTaskDefinition, Get-SevenTaskDefinitionHash
