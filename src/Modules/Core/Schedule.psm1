Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Configuration.psm1')
$script:TaskSecurity = 'D:P(A;;FA;;;SY)(A;;FA;;;BA)'
$script:DayNames = @('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')
$script:MonthNames = @('January','February','March','April','May','June','July','August','September','October','November','December')

function ConvertTo-DBXmlText {
    param([string] $Value)
    return [Security.SecurityElement]::Escape($Value)
}

function Get-DBTaskOwner {
    param([string] $ConfigPath)
    $canonical = [IO.Path]::GetFullPath($ConfigPath).ToUpperInvariant()
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical))).ToLowerInvariant()
}

function Get-DBTaskFolder {
    param([string] $InstanceName)
    Assert-DBIdentifier $InstanceName
    return "\DBBackup\$InstanceName\"
}

function Get-DBScheduleTask {
    param([Collections.IDictionary] $Configuration)
    if (-not $Configuration.Contains('Schedule')) { return @() }
    if ($Configuration.Schedule -isnot [Collections.IDictionary] -or -not $Configuration.Schedule.Contains('Tasks')) { throw 'Schedule.Tasks is required when Schedule is present.' }
    $result = @()
    $names = @{}
    foreach ($entry in $Configuration.Schedule.Tasks) {
        if ($entry -isnot [Collections.IDictionary]) { throw 'Schedule entries must be hashtables with explicit Job.' }
        foreach ($key in $entry.Keys) {
            if ($key -notin @('Name','Job','At','Frequency','Days','DaysOfMonth','Enabled')) { throw "Unknown schedule key: $key" }
        }
        foreach ($key in @('Name','Job','At')) { if (-not $entry.Contains($key)) { throw "Missing schedule field: $key" } }
        Assert-DBIdentifier $entry.Name
        if ($names.ContainsKey($entry.Name)) { throw 'Duplicate task name.' }
        $names[$entry.Name] = $true
        if ($entry.Job -cnotin @($Configuration.Jobs.Id)) { throw "Unknown schedule job: $($entry.Job)" }
        if ($entry.At -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { throw 'Invalid schedule time.' }
        $frequency = if ($entry.Contains('Frequency')) { [string] $entry.Frequency } else { 'Daily' }
        if ($frequency -cnotin @('Daily','Weekly','Monthly')) { throw 'Invalid schedule frequency.' }
        $days = @()
        $monthDays = @()
        if ($frequency -eq 'Weekly') {
            if (-not $entry.Contains('Days') -or @($entry.Days).Count -eq 0) { throw 'Weekly tasks require Days.' }
            foreach ($day in $entry.Days) { if ($day -cnotin $script:DayNames) { throw 'Invalid weekly day.' } }
            $days = @($script:DayNames | Where-Object { $_ -in $entry.Days })
        }
        elseif ($entry.Contains('Days')) { throw 'Days is only valid for Weekly tasks.' }
        if ($frequency -eq 'Monthly') {
            if (-not $entry.Contains('DaysOfMonth') -or @($entry.DaysOfMonth).Count -eq 0) { throw 'Monthly tasks require DaysOfMonth.' }
            foreach ($day in $entry.DaysOfMonth) {
                if ([string] $day -cne 'Last' -and [string] $day -notmatch '^(?:[1-9]|[12][0-9]|3[01])$') { throw 'Invalid monthly day.' }
            }
            $monthDays = @($entry.DaysOfMonth | Select-Object -Unique)
        }
        elseif ($entry.Contains('DaysOfMonth')) { throw 'DaysOfMonth is only valid for Monthly tasks.' }
        $enabled = $true
        if ($entry.Contains('Enabled')) {
            if ($entry.Enabled -isnot [bool]) { throw 'Enabled must be boolean.' }
            $enabled = $entry.Enabled
        }
        $result += [pscustomobject]@{Name=$entry.Name;Job=$entry.Job;At=$entry.At;Frequency=$frequency;Days=$days;DaysOfMonth=$monthDays;Enabled=$enabled}
    }
    return $result
}

function Test-DBScheduleRunsOn {
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

function Get-DBScheduleMaxGap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Tasks,
        [Parameter(Mandatory)][string] $Job
    )

    $covering = @($Tasks | Where-Object { $_.Enabled -and $_.Job -eq $Job })
    if ($covering.Count -eq 0) { return $null }

    $start = [DateTime]::new(2026, 1, 1)
    $runs = [System.Collections.Generic.List[DateTime]]::new()
    for ($offset = 0; $offset -lt 400; $offset++) {
        $date = $start.AddDays($offset)
        foreach ($task in $covering) {
            if (Test-DBScheduleRunsOn -Task $task -Date $date) {
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

function Get-DBScheduleNextRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Tasks,
        [Parameter(Mandatory)][string] $Job,
        [Parameter(Mandatory)][DateTime] $After
    )

    $covering = @($Tasks | Where-Object { $_.Enabled -and $_.Job -eq $Job })
    if ($covering.Count -eq 0) { return $null }

    $next = $null
    for ($offset = 0; $offset -lt 400 -and $null -eq $next; $offset++) {
        $date = $After.Date.AddDays($offset)
        foreach ($task in $covering) {
            if (-not (Test-DBScheduleRunsOn -Task $task -Date $date)) { continue }
            $run = $date.Add([TimeSpan]::Parse($task.At, [System.Globalization.CultureInfo]::InvariantCulture))
            if ($run -gt $After -and ($null -eq $next -or $run -lt $next)) { $next = $run }
        }
    }
    return $next
}

function Get-DBScheduleWarning {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Tasks)

    $warnings = @()
    foreach ($group in @($Tasks | Where-Object Enabled | Group-Object At | Where-Object Count -gt 1)) {
        $warnings += "Tarefas no mesmo horario ($($group.Name)): $(($group.Group.Name) -join ', '). So uma roda; as outras terminam com exit code 3."
    }
    return $warnings
}


function Get-DBTaskDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject] $Task,
        [Parameter(Mandatory)][string] $PwshPath,
        [Parameter(Mandatory)][string] $ScriptPath,
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [Parameter(Mandatory)][string] $ConfigPath,
        [ValidateRange(1, 72)][int] $ExecutionLimitHours = 12
    )

    $arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`" -ConfigPath `"$ConfigPath`" -Job $($Task.Job)"
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
    <ExecutionTimeLimit>PT$($ExecutionLimitHours)H</ExecutionTimeLimit>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$(ConvertTo-DBXmlText $PwshPath)</Command>
      <Arguments>$(ConvertTo-DBXmlText $arguments)</Arguments>
      <WorkingDirectory>$(ConvertTo-DBXmlText $WorkingDirectory)</WorkingDirectory>
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

    $owner = Get-DBTaskOwner $ConfigPath
    $description = "Gerenciada pelo DBBackup (config.psd1, secao Schedule). Alteracoes feitas aqui sao desfeitas ao aplicar a configuracao. [owner:$owner] [cfg:$hash]"
    $xml = @"
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>$(ConvertTo-DBXmlText $description)</Description>
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

function Get-DBTaskExecutionLimit {
    <#
    Scheduler hard stop: the run deadline (Execution.RunTimeoutSeconds) rounded
    up to whole hours plus one hour, so DBBackup reaches its own deadline first,
    publishes the failure, uploads its log and removes plaintext Work.
    #>
    param([Collections.IDictionary] $Configuration)
    $seconds = 39600
    if ($Configuration.Contains('Execution') -and $Configuration.Execution -is [Collections.IDictionary] -and $Configuration.Execution.Contains('RunTimeoutSeconds')) {
        $seconds = [long] $Configuration.Execution.RunTimeoutSeconds
    }
    return [int] ([Math]::Ceiling($seconds / 3600.0) + 1)
}

function Get-DBSchedulePlan {
    param([Collections.IDictionary] $Configuration, [AllowEmptyCollection()][object[]] $Existing,
        [string] $PwshPath, [string] $ScriptPath, [string] $WorkingDirectory)
    if (-not $Configuration.Contains('Schedule')) { return @() }
    $tasks = @(Get-DBScheduleTask $Configuration)
    $owner = Get-DBTaskOwner $Configuration.ConfigPath
    $limitHours = Get-DBTaskExecutionLimit $Configuration
    $plan = @()
    foreach ($old in $Existing) {
        [xml] $xml = $old.Xml
        if ([string] $xml.Task.RegistrationInfo.Description -notmatch "\[owner:$owner\]") {
            throw "Task ownership conflict: $($old.Name). No tasks were changed."
        }
    }
    foreach ($task in $tasks) {
        $definition = Get-DBTaskDefinition -Task $task -PwshPath $PwshPath -ScriptPath $ScriptPath -WorkingDirectory $WorkingDirectory -ConfigPath $Configuration.ConfigPath -ExecutionLimitHours $limitHours
        $old = @($Existing | Where-Object Name -EQ $task.Name)
        $action = 'Create'
        if ($old.Count -gt 0) {
            # Compare execution-relevant XML leaves; do not trust the description
            # fingerprint alone after an administrator edits a registered task.
            [xml] $actual = $old[0].Xml
            [xml] $expected = $definition.Xml
            $changed = $false
            $ns = [Xml.XmlNamespaceManager]::new($expected.NameTable)
            $ns.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
            foreach ($section in @('Triggers','Principals','Settings','Actions')) {
                foreach ($leaf in $expected.SelectNodes("/t:Task/t:$section//*[not(*)]", $ns)) {
                    $segments = @()
                    $node = $leaf
                    while ($node -is [Xml.XmlElement]) { $segments = @('t:' + $node.LocalName) + $segments; $node = $node.ParentNode }
                    $xpath = '/' + ($segments -join '/')
                    $other = $actual.SelectSingleNode($xpath, $ns)
                    if ($null -eq $other -or $other.InnerText -cne $leaf.InnerText) { $changed = $true }
                }
            }
            # Calendar subtrees have no scheduler-default fields to ignore.
            # Compare their full namespace-independent shape so added triggers
            # or repeated monthly days cannot hide behind an unchanged marker.
            if ((Get-DBXmlShape $actual.Task.Triggers) -cne (Get-DBXmlShape $expected.Task.Triggers)) { $changed = $true }
            if (-not $changed) { continue }
            $action = 'Update'
        }
        $plan += [pscustomobject]@{Action=$action;Name=$task.Name;Definition=$definition}
    }
    foreach ($old in $Existing) {
        if ($old.Name -notin @($tasks | ForEach-Object Name)) { $plan += [pscustomobject]@{Action='Remove';Name=$old.Name;Definition=$null} }
    }
    return $plan
}

function Get-DBXmlShape {
    param([Xml.XmlElement] $Element)
    $children = @($Element.ChildNodes | Where-Object { $_ -is [Xml.XmlElement] })
    if ($children.Count -eq 0) { return $Element.LocalName + ':' + $Element.InnerText }
    return $Element.LocalName + '(' + (($children | ForEach-Object { Get-DBXmlShape $_ }) -join ',') + ')'
}

function Get-DBSchedulerSnapshot {
    param([string] $FolderPath)
    $service = New-Object -ComObject 'Schedule.Service'
    $service.Connect()
    try { $folder = $service.GetFolder($FolderPath) }
    catch {
        if (Test-DBMissingTaskFolder $_.Exception) { return @() }
        throw
    }
    return @($folder.GetTasks(1) | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Xml = $_.Xml } })
}

function Test-DBMissingTaskFolder {
    param([Exception] $Exception)
    while ($null -ne $Exception) {
        if ($Exception.HResult -in @(-2147024894, -2147024893)) { return $true }
        $Exception = $Exception.InnerException
    }
    return $false
}

function Invoke-DBSchedulePlan {
    param([Collections.IDictionary] $Configuration, [AllowEmptyCollection()][object[]] $Plan)
    $service = New-Object -ComObject 'Schedule.Service'
    $service.Connect()
    $root = $service.GetFolder('\')
    try { $parent = $service.GetFolder('\DBBackup') }
    catch {
        if (-not (Test-DBMissingTaskFolder $_.Exception)) { throw }
        $parent = $root.CreateFolder('DBBackup', $script:TaskSecurity)
    }
    $path = Get-DBTaskFolder $Configuration.InstanceName
    try { $folder = $service.GetFolder($path) }
    catch {
        if (-not (Test-DBMissingTaskFolder $_.Exception)) { throw }
        $folder = $parent.CreateFolder($Configuration.InstanceName, $script:TaskSecurity)
    }
    $folder.SetSecurityDescriptor($script:TaskSecurity, 0)
    foreach ($item in $Plan) {
        if ($item.Action -eq 'Remove') { $folder.DeleteTask($item.Name, 0) }
        else { $null = $folder.RegisterTask($item.Name, $item.Definition.Xml, 6, 'SYSTEM', $null, 5, $script:TaskSecurity) }
    }
}

Export-ModuleMember -Function Get-DBTaskOwner, Get-DBTaskFolder, Get-DBScheduleTask, Get-DBTaskDefinition, Get-DBSchedulePlan, Get-DBSchedulerSnapshot, Invoke-DBSchedulePlan, Get-DBScheduleWarning, Get-DBScheduleMaxGap, Get-DBScheduleNextRun, Get-DBTaskExecutionLimit
