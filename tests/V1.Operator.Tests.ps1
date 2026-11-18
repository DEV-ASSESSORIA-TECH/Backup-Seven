BeforeAll {
    $script:Repo = Split-Path -Parent $PSScriptRoot
    foreach ($name in @('Configuration', 'Runtime', 'Process', 'Schedule', 'Setup')) { Import-Module "$script:Repo/src/App/Modules/Core/$name.psm1" }
    Import-Module "$script:Repo/src/App/Modules/Providers/SQLAnywhere/SQLAnywhere.psm1"
    . (Join-Path $PSScriptRoot 'V1.TestSupport.ps1')
    function New-TaskConfig([object[]] $Tasks) {
        @{ InstanceName = 'acme'; ConfigPath = 'C:\DBBackup\Instances\acme\config.psd1'; Jobs = @([pscustomobject]@{ Id = 'Database' }, [pscustomobject]@{ Id = 'fiscal' }); Schedule = @{ Tasks = $Tasks } }
    }
    function Get-Definition($Config) {
        Get-DBTaskDefinition -Task @(Get-DBScheduleTask $Config)[0] -PwshPath 'C:\pwsh.exe' -ScriptPath 'C:\DBBackup\App\Backup.ps1' -WorkingDirectory 'C:\DBBackup\App' -ConfigPath $Config.ConfigPath
    }
}

Describe 'Several times per scheduled task' {
    It 'registers one trigger per time in one task and keeps a single time unchanged' {
        $single = Get-Definition (New-TaskConfig @(@{ Name = 'banco'; Jobs = @('Database', 'fiscal'); At = '19:00' }))
        ([regex]::Matches($single.Xml, '<CalendarTrigger>')).Count | Should -Be 1
        $single.Xml | Should -Match '<StartBoundary>2026-01-01T19:00:00</StartBoundary>'
        $config = New-TaskConfig @(@{ Name = 'banco'; Jobs = @('Database', 'fiscal'); At = @('19:00', '12:30') })
        $task = @(Get-DBScheduleTask $config)[0]
        @($task.At) | Should -Be @('12:30', '19:00')
        $definition = Get-Definition $config
        ([regex]::Matches($definition.Xml, '<CalendarTrigger>')).Count | Should -Be 2
        $definition.Xml | Should -Match '2026-01-01T12:30:00'
        $definition.Xml | Should -Match '2026-01-01T19:00:00'
        $definition.Arguments | Should -Match '-Job Database,fiscal$'
        [xml] $definition.Xml | Should -Not -BeNullOrEmpty
        Get-DBScheduleNextRun -Tasks @($task) -Job fiscal -After ([datetime] '2026-11-18T13:00:00') | Should -Be ([datetime] '2026-11-18T19:00:00')
        Get-DBScheduleMaxGap -Tasks @($task) -Job Database | Should -Be 17.5
    }
    It 'warns about overlapping times and rejects repeated or invalid times' {
        $tasks = @(Get-DBScheduleTask (New-TaskConfig @(@{ Name = 'a'; Jobs = @('Database'); At = @('12:30', '19:00') }, @{ Name = 'b'; Jobs = @('fiscal'); At = '19:00' })))
        @(Get-DBScheduleWarning $tasks) | Should -Match '19:00.*a, b'
        { Get-DBScheduleTask (New-TaskConfig @(@{ Name = 'a'; Jobs = @('Database'); At = @('19:00', '19:00') })) } | Should -Throw '*repete um horario*'
        { Get-DBScheduleTask (New-TaskConfig @(@{ Name = 'a'; Jobs = @('Database'); At = @('12:30', '7:00') })) } | Should -Throw "*horario '7:00'*"
    }
    It 'explains an unknown job and points out a case mismatch' {
        { Get-DBScheduleTask (New-TaskConfig @(@{ Name = 'banco'; Jobs = @('database'); At = '19:00' })) } |
            Should -Throw "*tarefa 'banco' cita o job 'database'*use 'Database'*Jobs configurados: Database, fiscal*"
        { Get-DBScheduleTask (New-TaskConfig @(@{ Name = 'banco'; Jobs = @('nfe'); At = '19:00' })) } | Should -Throw "*job 'nfe'*Jobs configurados*"
    }
    It 'groups a job with exactly the same times in the setup' {
        @(ConvertTo-DBTimeList '19:00, 12:30;19:00') | Should -Be @('12:30', '19:00')
        { ConvertTo-DBTimeList '25:00' } | Should -Throw '*Horario invalido*'
        $data = @{ Schedule = @{ Tasks = @() } }
        Add-DBScheduledJob $data 'Database' @('12:30', '19:00')
        Add-DBScheduledJob $data 'fiscal' @('19:00', '12:30')
        Add-DBScheduledJob $data 'docs' @('19:00')
        $data.Schedule.Tasks.Count | Should -Be 2
        $data.Schedule.Tasks[0].Name | Should -Be 'diario-1230-1900'
        @($data.Schedule.Tasks[0].Jobs) | Should -Be @('Database', 'fiscal')
        @($data.Schedule.Tasks[0].At) | Should -Be @('12:30', '19:00')
        $data.Schedule.Tasks[1].At | Should -BeOfType [string]
        $data.Schedule.Tasks[1].Name | Should -Be 'diario-1900'
    }
}

Describe 'Tasks left by DBBackup 0.x and 1.x' {
    BeforeEach {
        $script:Deleted = [Collections.Generic.List[string]]::new()
        $script:Tree = @{
            '\' = @{ Tasks = @(); Folders = @('\DBBackup') }
            '\DBBackup' = @{ Tasks = @(@{ Name = 'acme-banco'; Args = '-File "C:\DBBackup\App\Backup.ps1" -Job x' }); Folders = @('\DBBackup\mysql-seven') }
            '\DBBackup\mysql-seven' = @{ Tasks = @(
                    @{ Name = 'mysql-seven-database-daily'; Args = '-File "C:\TI\DBBackup\Backup.ps1" -ConfigPath "C:\TI\DBBackup\Instances\mysql-seven\config.psd1" -Job database' }
                    @{ Name = 'outra-coisa'; Args = '-File "C:\scripts\limpeza.ps1"' }); Folders = @() }
        }
        function New-FakeFolder([string] $Path) {
            $folder = [pscustomobject]@{ Path = $Path }
            $folder | Add-Member ScriptMethod GetTasks {
                @($script:Tree[$this.Path].Tasks | ForEach-Object {
                    [pscustomobject]@{ Name = $_.Name; Xml = "<Task xmlns='http://schemas.microsoft.com/windows/2004/02/mit/task'><Actions><Exec><Command>pwsh.exe</Command><Arguments>$([Security.SecurityElement]::Escape($_.Args))</Arguments></Exec></Actions></Task>" }
                })
            }
            $folder | Add-Member ScriptMethod GetFolders { @($script:Tree[$this.Path].Folders | ForEach-Object { New-FakeFolder $_ }) }
            $folder | Add-Member ScriptMethod DeleteTask {
                $name = $args[0]; $script:Deleted.Add("$($this.Path)\$name")
                $script:Tree[$this.Path].Tasks = @($script:Tree[$this.Path].Tasks | Where-Object { $_.Name -ne $name })
            }
            $folder | Add-Member ScriptMethod DeleteFolder {
                $child = if ($this.Path -eq '\') { "\$($args[0])" } else { "$($this.Path)\$($args[0])" }
                $script:Deleted.Add("folder $child")
                $script:Tree[$this.Path].Folders = @($script:Tree[$this.Path].Folders | Where-Object { $_ -ne $child })
            }
            $folder
        }
        $script:Service = [pscustomobject]@{}
        $script:Service | Add-Member ScriptMethod GetFolder {
            param($Path)
            if (-not $script:Tree.ContainsKey($Path)) { throw [Runtime.InteropServices.COMException]::new('not found', -2147024894) }
            New-FakeFolder $Path
        }
        Mock New-DBSchedulerService { $script:Service } -ModuleName Schedule
    }
    It 'finds only backup tasks in the per-instance folders of 1.x' {
        $legacy = @(Get-DBLegacyTask)
        $legacy.Count | Should -Be 1
        $legacy[0].Folder | Should -Be '\DBBackup\mysql-seven'
        $legacy[0].Name | Should -Be 'mysql-seven-database-daily'
        $legacy[0].Arguments | Should -Match 'C:\\TI\\DBBackup\\Backup\.ps1'
    }
    It 'removes the tasks and the folder they leave empty' {
        Remove-DBLegacyTask @(Get-DBLegacyTask)
        $script:Deleted | Should -Contain '\DBBackup\mysql-seven\mysql-seven-database-daily'
        $script:Deleted | Should -Not -Contain 'folder \DBBackup\mysql-seven'
        $script:Tree['\DBBackup\mysql-seven'].Tasks = @()
        Remove-DBLegacyTask @([pscustomobject]@{ Folder = '\DBBackup\mysql-seven'; Name = 'gone' })
        $script:Deleted | Should -Contain 'folder \DBBackup\mysql-seven'
        @($script:Tree['\DBBackup'].Tasks).Count | Should -Be 1
    }
}

Describe 'Apply and operator launchers' {
    BeforeEach {
        $script:Instances = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:Config = Join-Path $script:Instances 'acme/config.psd1'
        $null = New-Item -ItemType Directory (Join-Path $script:Instances 'acme/Secrets') -Force
        Set-Content $script:Config ((Get-DBTestConfigText -RemoteRoot 's3:bucket-x/ACME' -InstanceName 'acme') -replace "(?m)^\s*Paths = .*\r?\n", '')
        Set-Content (Join-Path $script:Instances 'acme/Secrets/mysql.cnf') "[client]`nuser=u"
        Set-Content (Join-Path $script:Instances 'acme/Secrets/rclone.conf') '[s3]'
        Set-Content (Join-Path $script:Instances 'acme/Secrets/recipients.txt') ('age1' + ('q' * 58))
        Mock Set-Acl {} -ModuleName Runtime
        Mock Set-Acl {} -ModuleName Setup
        Mock Out-Host {} -ModuleName Setup
        Mock Out-Host {} -ModuleName Configuration
        Mock Test-DBInstance {} -ModuleName Setup
        Mock Invoke-DBScheduleApply {} -ModuleName Setup
    }
    It 'makes the instance Runtime private instead of refusing it, and offers to remove old tasks' {
        Mock Set-DBPrivateDirectory {} -ModuleName Setup
        Mock Get-DBLegacyTask { [pscustomobject]@{ Folder = '\DBBackup\mysql-seven'; Name = 'mysql-seven-database-daily'; Arguments = 'Backup.ps1' } } -ModuleName Setup
        Mock Remove-DBLegacyTask {} -ModuleName Setup
        Mock Read-Host { 'SIM' } -ModuleName Setup
        Invoke-DBConfigurationApply -Configuration (Read-DBConfiguration $script:Config) -InstancesRoot $script:Instances -ScriptPath 'C:\DBBackup\App\Backup.ps1' -PwshPath 'C:\pwsh.exe'
        Should -Invoke Set-DBPrivateDirectory -ModuleName Setup -Times 1 -Exactly -ParameterFilter { $Path -like '*acme*Runtime' -and $Force }
        Should -Invoke Remove-DBLegacyTask -ModuleName Setup -Times 1 -Exactly
    }
    It 'keeps old tasks unless the operator types SIM' {
        Mock Get-DBLegacyTask { [pscustomobject]@{ Folder = '\DBBackup\x'; Name = 't'; Arguments = 'Backup.ps1' } } -ModuleName Setup
        Mock Remove-DBLegacyTask {} -ModuleName Setup
        Mock Read-Host { 'sim' } -ModuleName Setup
        Invoke-DBConfigurationApply -Configuration (Read-DBConfiguration $script:Config) -InstancesRoot $script:Instances -ScriptPath 'C:\DBBackup\App\Backup.ps1' -PwshPath 'C:\pwsh.exe'
        Should -Invoke Remove-DBLegacyTask -ModuleName Setup -Times 0 -Exactly
    }
    It 'selects the only instance automatically and lists several by number' {
        Select-DBConfigPath $script:Instances | Should -Be (Join-Path $script:Instances 'acme/config.psd1')
        $null = New-Item -ItemType Directory (Join-Path $script:Instances 'beta') -Force
        Set-Content (Join-Path $script:Instances 'beta/config.psd1') 'x'
        $null = New-Item -ItemType Directory (Join-Path $script:Instances 'sem-config') -Force
        Mock Read-Host { '2' } -ModuleName Configuration
        Select-DBConfigPath $script:Instances | Should -Be (Join-Path $script:Instances 'beta/config.psd1')
        Mock Read-Host { '9' } -ModuleName Configuration
        Mock Write-Warning {} -ModuleName Configuration
        { Select-DBConfigPath $script:Instances } | Should -Throw '*Nenhuma configuracao selecionada*'
        Should -Invoke Read-Host -ModuleName Configuration -Times 4 -Exactly
    }
    It 'edits the configuration elevated, validates it and offers to apply' {
        Mock Read-Host { '' } -ModuleName Setup
        Mock Start-Process { $text = Get-Content $script:Config -Raw; Set-Content $script:Config $text.Replace("At = '19:00'", "At = @('12:30', '19:00')") } -ModuleName Setup
        Edit-DBConfiguration -ConfigPath $script:Config -InstancesRoot $script:Instances | Should -BeTrue
        @(Get-DBScheduleTask (Read-DBConfiguration $script:Config))[0].At | Should -Be @('12:30', '19:00')
        Should -Invoke Start-Process -ModuleName Setup -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'notepad.exe' -and $ArgumentList -like '*config.psd1"' }
    }
    It 'reopens or restores an invalid configuration' {
        $original = Get-Content $script:Config -Raw
        Mock Write-Warning {} -ModuleName Setup
        Mock Start-Process { Set-Content $script:Config '@{ SchemaVersion = 2' } -ModuleName Setup
        $script:Replies = [Collections.Generic.Queue[string]]::new([string[]] @('', 's', '', 'n', 's'))
        Mock Read-Host { $script:Replies.Dequeue() } -ModuleName Setup
        Edit-DBConfiguration -ConfigPath $script:Config -InstancesRoot $script:Instances | Should -BeFalse
        Should -Invoke Start-Process -ModuleName Setup -Times 2 -Exactly
        Get-Content $script:Config -Raw | Should -Be $original
    }
}

Describe 'Run feedback and native tool input' {
    It 'shows log lines on screen only when the console log is enabled' {
        $log = Join-Path $TestDrive 'run.log'
        Mock Out-Host {} -ModuleName Runtime
        try {
            Write-DBLog $log 'db' 'quiet'
            Should -Invoke Out-Host -ModuleName Runtime -Times 0 -Exactly
            Set-DBConsoleLog $true
            Write-DBLog $log 'db' 'Step 1/4 password=abc'
            Should -Invoke Out-Host -ModuleName Runtime -Times 1 -Exactly -ParameterFilter { $InputObject -match 'Step 1/4 password=\[REDACTED\]' }
        }
        finally { Set-DBConsoleLog $false }
        @(Get-Content $log).Count | Should -Be 2
    }
    It 'closes stdin so a tool that waits for input ends instead of hanging' {
        $pwsh = (Get-Process -Id $PID).Path
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-DBTool -Executable $pwsh -Arguments @('-NoProfile', '-NonInteractive', '-Command', '$line = [Console]::In.ReadLine(); if ($null -eq $line) { exit 7 } else { exit 1 }') -TimeoutSeconds 60
        $result.ExitCode | Should -Be 7
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 50
    }
    It 'estimates a SQL Anywhere database from dbping properties and falls back to unknown' {
        $bin = Join-Path $TestDrive 'sqla'
        $null = New-Item -ItemType Directory $bin -Force
        foreach ($name in 'dbbackup.exe', 'dbping.exe') { Set-Content (Join-Path $bin $name) 'x' }
        $credential = Join-Path $TestDrive 'dominio.options'
        Set-Content $credential "-c `"UID='dba';PWD='s3cr3t';SERVER='srv';DBN='contabil'`""
        $work = Join-Path $TestDrive 'work'
        $null = New-Item -ItemType Directory $work -Force
        $config = @{ Tools = @{ DbBackup = (Join-Path $bin 'dbbackup.exe') } }
        $job = [pscustomobject]@{ Id = 'dominio'; CredentialFile = $credential; Database = 'contabil' }
        Mock Invoke-DBTool { [pscustomobject]@{ ExitCode = 0; StdOut = "SQL Anywhere Server Ping Utility`nFileSize: 1500000`nPageSize: 4096`n"; StdErr = '' } } -ModuleName SQLAnywhere
        Get-DBSqlAnywhereSizeEstimate -Configuration $config -Job $job -Runtime ([pscustomobject]@{ Work = $work }) | Should -Be ([long] 1500000 * 4096)
        Should -Invoke Invoke-DBTool -ModuleName SQLAnywhere -ParameterFilter { ($Arguments -join ' ') -match '^-d -pd FileSize,PageSize @' }
        @(Get-ChildItem $work).Count | Should -Be 0
        Mock Invoke-DBTool { [pscustomobject]@{ ExitCode = 0; StdOut = 'unexpected'; StdErr = '' } } -ModuleName SQLAnywhere
        Get-DBSqlAnywhereSizeEstimate -Configuration $config -Job $job -Runtime ([pscustomobject]@{ Work = $work }) | Should -BeNullOrEmpty
        Mock Invoke-DBTool { [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'no server' } } -ModuleName SQLAnywhere
        Get-DBSqlAnywhereSizeEstimate -Configuration $config -Job $job -Runtime ([pscustomobject]@{ Work = $work }) | Should -BeNullOrEmpty
    }
}

Describe 'Monitoring in the guided setup' {
    It 'enables Alloy metrics and keeps backup_ids of an earlier version' {
        $alloy = Join-Path $TestDrive 'alloy'
        $null = New-Item -ItemType Directory $alloy -Force
        $data = @{ Jobs = @(@{ Id = 'Database' }, @{ Id = 'Fiscal' }); Monitoring = @{ Enabled = $false; Service = 'erp'; TextfileDirectory = $alloy; BackupIds = @{} } }
        $script:Replies = [Collections.Generic.Queue[string]]::new([string[]] @('', '', 'seven', 'database', ''))
        Mock Read-Host { $script:Replies.Dequeue() } -ModuleName Setup
        InModuleScope Setup -Parameters @{ Data = $data } { param($Data) Read-DBMonitoring $Data 'Seven' }
        $data.Monitoring.Enabled | Should -BeTrue
        $data.Monitoring.Service | Should -Be 'seven'
        $data.Monitoring.BackupIds.Database | Should -Be 'database'
        $data.Monitoring.BackupIds.Fiscal | Should -Be 'seven-fiscal'
    }
}
