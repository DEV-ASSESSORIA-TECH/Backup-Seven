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
    <#
    Every instance registers its tasks directly in \DBBackup\, named
    <instance>-<task>. Ownership comes from the [owner:...] marker in each
    task description, never from the folder.
    #>
    return '\DBBackup\'
}

function Get-DBTaskRegisteredName {
    param([Parameter(Mandatory)][string] $InstanceName, [Parameter(Mandatory)][string] $TaskName)
    Assert-DBIdentifier $InstanceName
    Assert-DBIdentifier $TaskName
    return "$InstanceName-$TaskName"
}

function Get-DBScheduleTask {
    param([Collections.IDictionary] $Configuration)
    if (-not $Configuration.Contains('Schedule')) { return @() }
    if ($Configuration.Schedule -isnot [Collections.IDictionary] -or -not $Configuration.Schedule.Contains('Tasks')) { throw 'Schedule.Tasks is required when Schedule is present.' }
    $result = @()
    $names = @{}
    foreach ($entry in $Configuration.Schedule.Tasks) {
        if ($entry -isnot [Collections.IDictionary]) { throw 'Schedule entries must be hashtables with explicit Jobs.' }
        foreach ($key in $entry.Keys) {
            if ($key -notin @('Name','Jobs','At','Frequency','Days','DaysOfMonth','Enabled')) { throw "Unknown schedule key: $key" }
        }
        foreach ($key in @('Name','Jobs','At')) { if (-not $entry.Contains($key)) { throw "Missing schedule field: $key (Schedule.Tasks precisa de Name, Jobs e At)" } }
        Assert-DBIdentifier $entry.Name
        if ($names.ContainsKey($entry.Name)) { throw "Duplicate task name: $($entry.Name)." }
        $names[$entry.Name] = $true
        # Jobs of one task run one after another in the same execution.
        $taskJobs = @($entry.Jobs | ForEach-Object { [string] $_ })
        if ($taskJobs.Count -eq 0) { throw "Schedule task $($entry.Name) has no jobs." }
        $configured = @($Configuration.Jobs | ForEach-Object { [string] $_.Id })
        foreach ($jobId in $taskJobs) {
            if ($jobId -cin $configured) { continue }
            # Job IDs are case-sensitive; point at the likely intended one.
            $similar = @($configured | Where-Object { $_ -ieq $jobId })
            $hint = if ($similar.Count) { " Maiusculas e minusculas importam: use '$($similar[0])'." } else { '' }
            throw "Unknown schedule job: tarefa '$($entry.Name)' cita o job '$jobId', que nao existe nesta instancia.$hint Jobs configurados: $($configured -join ', ')."
        }
        if (@($taskJobs | Select-Object -Unique).Count -ne $taskJobs.Count) { throw "Schedule task $($entry.Name) repeats a job." }
        # At is one time or a list of times ('12:30' or @('12:30','19:00')):
        # each time becomes a trigger of the same task.
        $times = @($entry.At | ForEach-Object { [string] $_ })
        if ($times.Count -eq 0) { throw "Invalid schedule time: tarefa '$($entry.Name)' sem horario em At." }
        foreach ($time in $times) {
            if ($time -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { throw "Invalid schedule time: tarefa '$($entry.Name)', horario '$time' (use HH:mm, por exemplo '19:00' ou @('12:30', '19:00'))." }
        }
        if (@($times | Select-Object -Unique).Count -ne $times.Count) { throw "Invalid schedule time: tarefa '$($entry.Name)' repete um horario." }
        $times = @($times | Sort-Object)
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
        $registered = Get-DBTaskRegisteredName -InstanceName $Configuration.InstanceName -TaskName $entry.Name
        $result += [pscustomobject]@{Name=$entry.Name;RegisteredName=$registered;Jobs=$taskJobs;At=$times;Frequency=$frequency;Days=$days;DaysOfMonth=$monthDays;Enabled=$enabled}
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

    $covering = @($Tasks | Where-Object { $_.Enabled -and $Job -cin @($_.Jobs) })
    if ($covering.Count -eq 0) { return $null }

    $start = [DateTime]::new(2026, 1, 1)
    $runs = [System.Collections.Generic.List[DateTime]]::new()
    for ($offset = 0; $offset -lt 400; $offset++) {
        $date = $start.AddDays($offset)
        foreach ($task in $covering) {
            if (Test-DBScheduleRunsOn -Task $task -Date $date) {
                foreach ($time in @($task.At)) { $runs.Add($date.Add([TimeSpan]::Parse($time, [System.Globalization.CultureInfo]::InvariantCulture))) }
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

    $covering = @($Tasks | Where-Object { $_.Enabled -and $Job -cin @($_.Jobs) })
    if ($covering.Count -eq 0) { return $null }

    $next = $null
    for ($offset = 0; $offset -lt 400 -and $null -eq $next; $offset++) {
        $date = $After.Date.AddDays($offset)
        foreach ($task in $covering) {
            if (-not (Test-DBScheduleRunsOn -Task $task -Date $date)) { continue }
            foreach ($time in @($task.At)) {
                $run = $date.Add([TimeSpan]::Parse($time, [System.Globalization.CultureInfo]::InvariantCulture))
                if ($run -gt $After -and ($null -eq $next -or $run -lt $next)) { $next = $run }
            }
        }
    }
    return $next
}

function Get-DBScheduleWarning {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Tasks)

    $warnings = @()
    $starts = @(foreach ($task in @($Tasks | Where-Object Enabled)) { foreach ($time in @($task.At)) { [pscustomobject]@{ At = $time; Name = $task.Name } } })
    foreach ($group in @($starts | Group-Object At | Where-Object Count -gt 1)) {
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

    $arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`" -ConfigPath `"$ConfigPath`" -Job $(@($Task.Jobs) -join ',')"
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

    # One calendar trigger per time; a single time keeps the 2.0 XML.
    $triggers = (@($Task.At) | ForEach-Object {
        @"
    <CalendarTrigger>
      <StartBoundary>2026-01-01T$($_):00</StartBoundary>
      <Enabled>true</Enabled>
      $schedule
    </CalendarTrigger>
"@
    }) -join "`n"
    $body = @"
  <Triggers>
$triggers
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
    $registeredProperty = $Task.PSObject.Properties['RegisteredName']
    [pscustomobject]@{
        Name      = if ($null -ne $registeredProperty -and $registeredProperty.Value) { [string] $registeredProperty.Value } else { $Task.Name }
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
    # The \DBBackup\ folder is shared by every instance: only tasks carrying
    # this configuration's owner marker are compared, updated or removed.
    $owned = @()
    $foreign = @()
    foreach ($old in $Existing) {
        $description = ''
        try { [xml] $xml = $old.Xml; $description = [string] $xml.Task.RegistrationInfo.Description } catch { $description = '' }
        if ($description -match "\[owner:$owner\]") { $owned += $old } else { $foreign += $old }
    }
    foreach ($task in $tasks) {
        # Task Scheduler names are case-insensitive.
        if (@($foreign | Where-Object { $_.Name -ieq $task.RegisteredName }).Count -gt 0) {
            throw "Task name conflict: $($task.RegisteredName) already exists in $(Get-DBTaskFolder) and belongs to another configuration. No tasks were changed."
        }
    }
    foreach ($task in $tasks) {
        $definition = Get-DBTaskDefinition -Task $task -PwshPath $PwshPath -ScriptPath $ScriptPath -WorkingDirectory $WorkingDirectory -ConfigPath $Configuration.ConfigPath -ExecutionLimitHours $limitHours
        $old = @($owned | Where-Object { $_.Name -ieq $task.RegisteredName })
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
        $plan += [pscustomobject]@{Action=$action;Name=$task.RegisteredName;Definition=$definition}
    }
    foreach ($old in $owned) {
        if ($old.Name -notin @($tasks | ForEach-Object RegisteredName)) { $plan += [pscustomobject]@{Action='Remove';Name=$old.Name;Definition=$null} }
    }
    return $plan
}

function Get-DBXmlShape {
    param([Xml.XmlElement] $Element)
    $children = @($Element.ChildNodes | Where-Object { $_ -is [Xml.XmlElement] })
    if ($children.Count -eq 0) { return $Element.LocalName + ':' + $Element.InnerText }
    return $Element.LocalName + '(' + (($children | ForEach-Object { Get-DBXmlShape $_ }) -join ',') + ')'
}

function New-DBSchedulerService {
    <# Connected Task Scheduler COM service; a seam so tests can simulate it. #>
    $service = New-Object -ComObject 'Schedule.Service'
    $service.Connect()
    return $service
}

function ConvertTo-DBSchedulerFolderPath {
    <#
    Get-DBTaskFolder returns the display form with a trailing separator
    (\DBBackup\<instance>\). ITaskService.GetFolder rejects a trailing
    separator with 0x8007007B (invalid name), so it is removed for COM calls;
    the root folder stays '\'.
    #>
    param([Parameter(Mandatory)][string] $FolderPath)
    $trimmed = $FolderPath.TrimEnd('\')
    if ([string]::IsNullOrEmpty($trimmed)) { return '\' }
    return $trimmed
}

function Get-DBSchedulerSnapshot {
    param([string] $FolderPath)
    $service = New-DBSchedulerService
    try { $folder = $service.GetFolder((ConvertTo-DBSchedulerFolderPath $FolderPath)) }
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
    # Defense in depth for the shared folder: a plan may only touch tasks named
    # after this instance (Get-DBSchedulePlan already filtered by owner).
    $prefix = "$($Configuration.InstanceName)-"
    foreach ($item in $Plan) {
        if (-not ([string] $item.Name).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to change task $($item.Name): it is not named after instance $($Configuration.InstanceName)." }
    }
    $service = New-DBSchedulerService
    $root = $service.GetFolder('\')
    try { $folder = $service.GetFolder((ConvertTo-DBSchedulerFolderPath (Get-DBTaskFolder))) }
    catch {
        if (-not (Test-DBMissingTaskFolder $_.Exception)) { throw }
        $folder = $root.CreateFolder('DBBackup', $script:TaskSecurity)
    }
    $folder.SetSecurityDescriptor($script:TaskSecurity, 0)
    foreach ($item in $Plan) {
        if ($item.Action -eq 'Remove') { $folder.DeleteTask($item.Name, 0) }
        else { $null = $folder.RegisterTask($item.Name, $item.Definition.Xml, 6, 'SYSTEM', $null, 5, $script:TaskSecurity) }
    }
}

function Get-DBLegacyTask {
    <#
    Tasks registered by earlier versions that are not managed by 2.x: the
    per-instance folders \DBBackup\<instance>\ (1.x) and \BackupSeven\ (0.x).
    Only tasks whose action runs a Backup*.ps1 script are returned.
    #>
    $service = New-DBSchedulerService
    $folders = @()
    foreach ($path in @('\DBBackup', '\BackupSeven')) {
        try { $folder = $service.GetFolder($path) }
        catch {
            if (Test-DBMissingTaskFolder $_.Exception) { continue }
            throw
        }
        if ($path -eq '\BackupSeven') { $folders += $folder }
        $folders += @($folder.GetFolders(0))
    }
    foreach ($folder in $folders) {
        foreach ($task in @($folder.GetTasks(1))) {
            try { [xml] $xml = $task.Xml } catch { continue }
            $arguments = (@($xml.Task.Actions.Exec) | ForEach-Object { [string] $_.Arguments }) -join ' '
            if ($arguments -match '(?i)Backup[^\\/"]*\.ps1') {
                [pscustomobject]@{ Folder = [string] $folder.Path; Name = [string] $task.Name; Arguments = $arguments }
            }
        }
    }
}

function Remove-DBLegacyTask {
    <# Deletes the given legacy tasks, then each of their folders left empty. #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Task)
    $service = New-DBSchedulerService
    foreach ($item in $Task) { $service.GetFolder($item.Folder).DeleteTask($item.Name, 0) }
    foreach ($path in @($Task | ForEach-Object Folder | Select-Object -Unique)) {
        $folder = $service.GetFolder($path)
        if (@($folder.GetTasks(1)).Count -or @($folder.GetFolders(0)).Count) { continue }
        # Scheduler paths always use '\' (also when tests run off Windows).
        $index = $path.LastIndexOf('\')
        $parentPath = if ($index -le 0) { '\' } else { $path.Substring(0, $index) }
        $service.GetFolder($parentPath).DeleteFolder($path.Substring($index + 1), 0)
    }
}

Export-ModuleMember -Function Get-DBTaskOwner, Get-DBTaskFolder, Get-DBTaskRegisteredName, Get-DBScheduleTask, Get-DBTaskDefinition, Get-DBSchedulePlan, ConvertTo-DBSchedulerFolderPath, Get-DBSchedulerSnapshot, Invoke-DBSchedulePlan, Get-DBScheduleWarning, Get-DBScheduleMaxGap, Get-DBScheduleNextRun, Get-DBTaskExecutionLimit, Get-DBLegacyTask, Remove-DBLegacyTask
