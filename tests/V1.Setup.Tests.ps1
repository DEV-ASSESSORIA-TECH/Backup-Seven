BeforeAll {
    $script:Repo=Split-Path -Parent $PSScriptRoot
    Import-Module "$script:Repo/src/Modules/Core/Configuration.psm1"
    Import-Module "$script:Repo/src/Modules/Core/Runtime.psm1"
    Import-Module "$script:Repo/src/Modules/Core/Schedule.psm1"
    Import-Module "$script:Repo/src/Modules/Core/Setup.psm1"
    function New-TestDefinition($C) {
        $task=@(Get-DBScheduleTask $C)[0]
        Get-DBTaskDefinition -Task $task -PwshPath 'C:\Program Files\PowerShell\7\pwsh.exe' -ScriptPath 'C:\DBBackup\Backup.ps1' -WorkingDirectory 'C:\DBBackup' -ConfigPath $C.ConfigPath
    }
    function Get-TestPlan($C, [object[]] $Existing=@()) {
        @(Get-DBSchedulePlan -Configuration $C -Existing $Existing -PwshPath 'C:\Program Files\PowerShell\7\pwsh.exe' -ScriptPath 'C:\DBBackup\Backup.ps1' -WorkingDirectory 'C:\DBBackup')
    }
}
Describe 'DBBackup task identity and reconciliation' {
    BeforeEach {
        $script:C=@{InstanceName='MySQL';ConfigPath='C:\DBBackup\Instances\MySQL\config.psd1';Jobs=@([pscustomobject]@{Id='database'},[pscustomobject]@{Id='files'});Schedule=@{Tasks=@(@{Name='daily';Job='database';At='19:00'})}}
    }
    It 'uses explicit config/job, SYSTEM, protected tasks and a generic folder' {
        $definition=New-TestDefinition $script:C
        $definition.Arguments | Should -Match '-ConfigPath "C:\\DBBackup\\Instances\\MySQL\\config.psd1" -Job database'
        $definition.Xml | Should -Match 'S-1-5-18'
        $definition.Xml | Should -Match 'PT12H'
        Get-DBTaskExecutionLimit $script:C | Should -Be 12
        $script:C.Execution=@{RunTimeoutSeconds=72000}
        Get-DBTaskExecutionLimit $script:C | Should -Be 21
        (Get-TestPlan $script:C)[0].Definition.Xml | Should -Match 'PT21H'
        $definition.Xml | Should -Not -Match 'Seven|Fiscal|-Mode'
        Get-DBTaskFolder 'SQLAnywhere' | Should -Be '\DBBackup\SQLAnywhere\'
    }
    It 'has an empty plan when the registered definition is unchanged' {
        $d=New-TestDefinition $script:C
        @(Get-TestPlan $script:C @([pscustomobject]@{Name='daily';Xml=$d.Xml})).Count | Should -Be 0
    }
    It 'detects edited actions even when their description fingerprint is unchanged' {
        $d=New-TestDefinition $script:C
        $old=[pscustomobject]@{Name='daily';Xml=$d.Xml.Replace('-Job database','-Job files')}
        (Get-TestPlan $script:C @($old)).Action | Should -Be Update
    }
    It 'refuses to adopt tasks owned by another configuration' {
        $d=New-TestDefinition $script:C
        $script:C.ConfigPath='C:\DBBackup\Instances\SQLAnywhere\config.psd1'
        { Get-TestPlan $script:C @([pscustomobject]@{Name='daily';Xml=$d.Xml}) } | Should -Throw '*ownership conflict*'
    }
    It 'detects extra calendar triggers even with the original fingerprint' {
        $d=New-TestDefinition $script:C
        $old=[pscustomobject]@{Name='daily';Xml=$d.Xml.Replace('</Triggers>', '<CalendarTrigger><StartBoundary>2026-01-01T01:00:00</StartBoundary><ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay></CalendarTrigger></Triggers>')}
        (Get-TestPlan $script:C @($old)).Action | Should -Be Update
    }
    It 'only removes owned tasks and leaves missing Schedule unmanaged' {
        $d=New-TestDefinition $script:C
        $existing=@([pscustomobject]@{Name='daily';Xml=$d.Xml})
        $script:C.Schedule.Tasks=@()
        (Get-TestPlan $script:C $existing).Action | Should -Be Remove
        $script:C.Remove('Schedule')
        @(Get-TestPlan $script:C $existing).Count | Should -Be 0
    }
    It 'validates weekly and monthly calendars with arbitrary job IDs' {
        $script:C.Schedule.Tasks=@(@{Name='weekly';Job='files';At='03:00';Frequency='Weekly';Days=@('Saturday')},@{Name='monthly';Job='database';At='04:00';Frequency='Monthly';DaysOfMonth=@(1,'Last')})
        $tasks=@(Get-DBScheduleTask $script:C)
        $tasks.Count | Should -Be 2
        Get-DBScheduleNextRun -Tasks $tasks -Job files -After ([datetime]'2026-11-17T00:00:00') | Should -Be ([datetime]'2026-11-21T03:00:00')
        $script:C.Schedule.Tasks[0].Job='unknown'
        { Get-DBScheduleTask $script:C } | Should -Throw '*Unknown*'
    }
    It 'recognizes wrapped missing-folder COM errors without swallowing access denied' {
        InModuleScope Schedule {
            $missing=[Runtime.InteropServices.COMException]::new('missing', -2147024894)
            $wrapped=[Management.Automation.MethodInvocationException]::new('wrapped', $missing)
            Test-DBMissingTaskFolder $wrapped | Should -BeTrue
            Test-DBMissingTaskFolder ([Runtime.InteropServices.COMException]::new('denied', -2147024891)) | Should -BeFalse
        }
    }
}
Describe 'Task Scheduler COM paths' {
    BeforeEach {
        # Mirrors ITaskService.GetFolder: a trailing separator is an invalid
        # name (0x8007007B); an absent folder is "not found" (0x80070002).
        $script:Requested = [Collections.Generic.List[string]]::new()
        $script:Registered = [Collections.Generic.List[string]]::new()
        $script:Existing = [Collections.Generic.HashSet[string]]::new([string[]]@('\'))
        function New-FakeFolder([string] $Path) {
            $folder = [pscustomobject]@{ Path = $Path }
            # COM-shaped methods; extra COM arguments arrive in $args and are ignored.
            $folder | Add-Member ScriptMethod CreateFolder { $name = $args[0]; $child = if ($this.Path -eq '\') { "\$name" } else { "$($this.Path)\$name" }; $null = $script:Existing.Add($child); New-FakeFolder $child }
            $folder | Add-Member ScriptMethod GetTasks { @() }
            $folder | Add-Member ScriptMethod SetSecurityDescriptor { }
            $folder | Add-Member ScriptMethod RegisterTask { $script:Registered.Add("$($this.Path)|$($args[0])") }
            $folder | Add-Member ScriptMethod DeleteTask { }
            $folder
        }
        $script:Service = [pscustomobject]@{}
        $script:Service | Add-Member ScriptMethod GetFolder {
            param($Path)
            $script:Requested.Add($Path)
            if ($Path.Length -gt 1 -and $Path.EndsWith('\')) { throw [Runtime.InteropServices.COMException]::new('invalid name', -2147024773) }
            if (-not $script:Existing.Contains($Path)) { throw [Runtime.InteropServices.COMException]::new('not found', -2147024894) }
            New-FakeFolder $Path
        }
        Mock New-DBSchedulerService { $script:Service } -ModuleName Schedule
    }
    It 'reads a missing instance folder without a trailing separator' {
        @(Get-DBSchedulerSnapshot (Get-DBTaskFolder 'ASSESSORIA')).Count | Should -Be 0
        $script:Requested | Should -Be @('\DBBackup\ASSESSORIA')
    }
    It 'creates the folders and registers tasks using valid COM paths' {
        $c=@{InstanceName='ASSESSORIA';ConfigPath='C:\DBBackup\Instances\ASSESSORIA\config.psd1';Jobs=@([pscustomobject]@{Id='database'});Schedule=@{Tasks=@(@{Name='daily';Job='database';At='19:00'})}}
        $plan=@(Get-TestPlan $c)
        Invoke-DBSchedulePlan -Configuration $c -Plan $plan
        $script:Requested | Where-Object { $_.Length -gt 1 -and $_.EndsWith('\') } | Should -BeNullOrEmpty
        $script:Registered | Should -Be @('\DBBackup\ASSESSORIA|daily')
        ConvertTo-DBSchedulerFolderPath '\' | Should -Be '\'
    }
}
Describe 'Unified setup and secrets' {
    BeforeEach {
        $script:Instances=Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:Config=Join-Path $script:Instances 'MySQL/config.psd1'
        Mock Set-Acl {} -ModuleName Runtime
        Mock Set-Acl {} -ModuleName Setup
    }
    It 'creates an isolated config and refuses to overwrite it' {
        $path=Initialize-DBInstance -ConfigPath $script:Config -Provider MySQL -InstanceName MySQL -TemplateRoot "$script:Repo/src/Templates" -InstancesRoot $script:Instances
        (Read-DBConfiguration $path).Provider | Should -Be MySQL
        { Initialize-DBInstance -ConfigPath $script:Config -Provider MySQL -InstanceName MySQL -TemplateRoot "$script:Repo/src/Templates" -InstancesRoot $script:Instances } | Should -Throw '*overwrite*'
    }
    It 'refuses duplicate instance names before persisting another config' {
        $null=Initialize-DBInstance -ConfigPath $script:Config -Provider MySQL -InstanceName MySQL -TemplateRoot "$script:Repo/src/Templates" -InstancesRoot $script:Instances
        $other=Join-Path $script:Instances 'Other/config.psd1'
        { Initialize-DBInstance -ConfigPath $other -Provider SQLAnywhere -InstanceName MySQL -TemplateRoot "$script:Repo/src/Templates" -InstancesRoot $script:Instances } | Should -Throw '*Duplicate*'
        Test-Path $other | Should -BeFalse
    }
    It 'rejects an enclosing instance before altering its existing child permissions' {
        $child=Join-Path $script:Instances 'parent/child/config.psd1'
        $null=Initialize-DBInstance -ConfigPath $child -Provider MySQL -InstanceName Child -TemplateRoot "$script:Repo/src/Templates" -InstancesRoot $script:Instances
        $parent=Join-Path $script:Instances 'parent/config.psd1'
        { Initialize-DBInstance -ConfigPath $parent -Provider MySQL -InstanceName Parent -TemplateRoot "$script:Repo/src/Templates" -InstancesRoot $script:Instances } | Should -Throw '*share*'
        Test-Path $parent | Should -BeFalse
    }
    It 'never prompts for or overwrites existing secrets' {
        $null=Initialize-DBInstance -ConfigPath $script:Config -Provider MySQL -InstanceName MySQL -TemplateRoot "$script:Repo/src/Templates" -InstancesRoot $script:Instances
        $c=Read-DBConfiguration $script:Config
        foreach ($file in @($c.Database.DefaultsExtraFile,$c.Storage.ConfigPath,$c.Encryption.RecipientsFile)) {Set-Content $file 'preserve exactly'}
        Mock Read-Host { throw 'Unexpected prompt' } -ModuleName Setup
        Initialize-DBSecret $c
        foreach ($file in @($c.Database.DefaultsExtraFile,$c.Storage.ConfigPath,$c.Encryption.RecipientsFile)) { Get-Content $file -Raw | Should -Match '^preserve exactly\s*$' }
        Should -Invoke Read-Host -ModuleName Setup -Times 0 -Exactly
    }
    It 'plans without creating state directories, modifying config or applying tasks' {
        $null=Initialize-DBInstance -ConfigPath $script:Config -Provider MySQL -InstanceName MySQL -TemplateRoot "$script:Repo/src/Templates" -InstancesRoot $script:Instances
        $before=(Get-FileHash $script:Config).Hash
        Mock Get-DBSchedulerSnapshot { @() } -ModuleName Setup
        Mock Invoke-DBSchedulePlan { throw 'Unexpected task mutation' } -ModuleName Setup
        $plan=@(Invoke-DBConfigurationApply -Configuration (Read-DBConfiguration $script:Config) -InstancesRoot $script:Instances -ScriptPath 'C:\DBBackup\Backup.ps1' -PwshPath 'C:\pwsh.exe' -PlanOnly)
        $plan.Action | Should -Be Create
        (Get-FileHash $script:Config).Hash | Should -Be $before
        Test-Path (Join-Path (Split-Path $script:Config) 'Runtime') | Should -BeFalse
        Should -Invoke Invoke-DBSchedulePlan -ModuleName Setup -Times 0 -Exactly
    }
    It 'serializes literal values without interpreting embedded PowerShell' {
        $path=Join-Path $TestDrive 'roundtrip.psd1'
        $value=@{Name="O'Brien";Literal='$(should-never-run)';Enabled=$true;Items=@(1,'Last')}
        Set-Content $path (ConvertTo-DBDataLiteral $value)
        $copy=Import-PowerShellDataFile $path
        $copy.Name | Should -Be "O'Brien"
        $copy.Literal | Should -Be '$(should-never-run)'
        $copy.Items | Should -Be @(1,'Last')
    }
    It 'performs local diagnostics without changing instance files or scheduler state' {
        $null=Initialize-DBInstance -ConfigPath $script:Config -Provider SQLAnywhere -InstanceName SQLAnywhere -TemplateRoot "$script:Repo/src/Templates" -InstancesRoot $script:Instances
        $c=Read-DBConfiguration $script:Config
        # Replace placeholders before invoking diagnostics; never use real credentials.
        Set-Content $script:Config ((Get-Content $script:Config -Raw).Replace('REPLACE_DATABASE','demo').Replace('REPLACE_BUCKET','demo'))
        $c=Read-DBConfiguration $script:Config
        Set-Content $c.Database.ConnectionOptionsFile '-c "UID=u;PWD=p;HOST=192.0.2.1:2638;DBN=demo"'
        Set-Content $c.Storage.ConfigPath '[s3]'
        Set-Content $c.Encryption.RecipientsFile ('age1'+('q'*58))
        $before=@(Get-ChildItem (Split-Path $script:Config) -Recurse -File | Get-FileHash | ForEach-Object Hash)
        Mock Test-DBPrivateAcl {} -ModuleName Setup
        Mock Assert-DBBackupDependency {} -ModuleName Setup
        Mock Get-DBSchedulerSnapshot { throw 'Diagnostics must not inspect scheduler.' } -ModuleName Setup
        (Test-DBInstance $c $script:Instances).Status | Should -Be LOCAL_CHECKS_OK
        $after=@(Get-ChildItem (Split-Path $script:Config) -Recurse -File | Get-FileHash | ForEach-Object Hash)
        $after | Should -Be $before
        Should -Invoke Get-DBSchedulerSnapshot -ModuleName Setup -Times 0 -Exactly
    }
    It 'validates age recipients before writing and re-prompts on invalid input' {
        $null=Initialize-DBInstance -ConfigPath $script:Config -Provider MySQL -InstanceName MySQL -TemplateRoot "$script:Repo/src/Templates" -InstancesRoot $script:Instances
        $c=Read-DBConfiguration $script:Config
        foreach ($file in @($c.Database.DefaultsExtraFile,$c.Storage.ConfigPath)) {Set-Content $file 'preserve exactly'}
        $script:Answers=[Collections.Generic.Queue[string]]::new([string[]]@('AGE-SECRET-KEY-1PRIVATE', ('age1'+('q'*58))))
        Mock Read-Host { $script:Answers.Dequeue() } -ModuleName Setup
        Mock Write-Warning {} -ModuleName Setup
        Initialize-DBSecret $c
        (Get-Content $c.Encryption.RecipientsFile -Raw).Trim() | Should -Be ('age1'+('q'*58))
        Should -Invoke Write-Warning -ModuleName Setup -Times 1 -Exactly
    }
    It 'gives up after three invalid recipient answers without creating the file' {
        $null=Initialize-DBInstance -ConfigPath $script:Config -Provider MySQL -InstanceName MySQL -TemplateRoot "$script:Repo/src/Templates" -InstancesRoot $script:Instances
        $c=Read-DBConfiguration $script:Config
        foreach ($file in @($c.Database.DefaultsExtraFile,$c.Storage.ConfigPath)) {Set-Content $file 'preserve exactly'}
        Mock Read-Host { '' } -ModuleName Setup
        Mock Write-Warning {} -ModuleName Setup
        { Initialize-DBSecret $c } | Should -Throw '*recipient*'
        Test-Path $c.Encryption.RecipientsFile | Should -BeFalse
    }
    It 'writes the chosen S3 provider and optional endpoint to rclone' {
        $null=Initialize-DBInstance -ConfigPath $script:Config -Provider MySQL -InstanceName MySQL -TemplateRoot "$script:Repo/src/Templates" -InstancesRoot $script:Instances
        $c=Read-DBConfiguration $script:Config
        foreach ($file in @($c.Database.DefaultsExtraFile,$c.Encryption.RecipientsFile)) {Set-Content $file 'preserve exactly'}
        Mock Read-Host {
            param($Prompt, [switch] $AsSecureString)
            if ($AsSecureString) { $secure=[Security.SecureString]::new(); foreach ($ch in 'secret-value'.ToCharArray()) { $secure.AppendChar($ch) }; return $secure }
            switch -Wildcard ($Prompt) {
                'Provedor*' { 'Wasabi' }
                'Endpoint*' { 's3.wasabisys.com' }
                'Access*' { 'AKIDTEST' }
                default { '' }
            }
        } -ModuleName Setup
        Initialize-DBSecret $c
        $text=Get-Content $c.Storage.ConfigPath -Raw
        $text | Should -Match '(?m)^provider = Wasabi$'
        $text | Should -Match '(?m)^endpoint = s3\.wasabisys\.com$'
        $text | Should -Match '(?m)^secret_access_key = secret-value$'
    }
}
