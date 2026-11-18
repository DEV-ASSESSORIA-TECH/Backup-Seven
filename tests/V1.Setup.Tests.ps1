BeforeAll {
    $script:Repo=Split-Path -Parent $PSScriptRoot
    Import-Module "$script:Repo/src/Modules/Core/Configuration.psm1"
    Import-Module "$script:Repo/src/Modules/Core/Runtime.psm1"
    Import-Module "$script:Repo/src/Modules/Core/Schedule.psm1"
    Import-Module "$script:Repo/src/Modules/Core/Setup.psm1"
    Import-Module "$script:Repo/src/Modules/Providers/SQLAnywhere/SQLAnywhere.psm1"
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
        Get-DBTaskFolder | Should -Be '\DBBackup\'
        $definition.Name | Should -Be 'MySQL-daily'
    }
    It 'has an empty plan when the registered definition is unchanged' {
        $d=New-TestDefinition $script:C
        @(Get-TestPlan $script:C @([pscustomobject]@{Name='MySQL-daily';Xml=$d.Xml})).Count | Should -Be 0
    }
    It 'detects edited actions even when their description fingerprint is unchanged' {
        $d=New-TestDefinition $script:C
        $old=[pscustomobject]@{Name='MySQL-daily';Xml=$d.Xml.Replace('-Job database','-Job files')}
        (Get-TestPlan $script:C @($old)).Action | Should -Be Update
    }
    It 'refuses a task name owned by another configuration in the shared folder' {
        $d=New-TestDefinition $script:C
        $script:C.ConfigPath='C:\DBBackup\Instances\Other\config.psd1'
        { Get-TestPlan $script:C @([pscustomobject]@{Name='mysql-DAILY';Xml=$d.Xml}) } | Should -Throw '*name conflict*'
    }
    It 'ignores tasks of other instances in the shared folder' {
        $other=@{InstanceName='SQLAnywhere';ConfigPath='C:\DBBackup\Instances\SQLAnywhere\config.psd1';Jobs=@([pscustomobject]@{Id='database'});Schedule=@{Tasks=@(@{Name='daily';Job='database';At='02:00'})}}
        $foreign=[pscustomobject]@{Name='SQLAnywhere-daily';Xml=(New-TestDefinition $other).Xml}
        $plan=@(Get-TestPlan $script:C @($foreign))
        $plan.Count | Should -Be 1
        $plan[0].Action | Should -Be Create
        $plan[0].Name | Should -Be 'MySQL-daily'
        $script:C.Schedule.Tasks=@()
        @(Get-TestPlan $script:C @($foreign)).Count | Should -Be 0
    }
    It 'detects extra calendar triggers even with the original fingerprint' {
        $d=New-TestDefinition $script:C
        $old=[pscustomobject]@{Name='MySQL-daily';Xml=$d.Xml.Replace('</Triggers>', '<CalendarTrigger><StartBoundary>2026-01-01T01:00:00</StartBoundary><ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay></CalendarTrigger></Triggers>')}
        (Get-TestPlan $script:C @($old)).Action | Should -Be Update
    }
    It 'only removes owned tasks and leaves missing Schedule unmanaged' {
        $d=New-TestDefinition $script:C
        $existing=@([pscustomobject]@{Name='MySQL-daily';Xml=$d.Xml})
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
        @(Get-DBSchedulerSnapshot (Get-DBTaskFolder)).Count | Should -Be 0
        $script:Requested | Should -Be @('\DBBackup')
    }
    It 'creates the folders and registers tasks using valid COM paths' {
        $c=@{InstanceName='ASSESSORIA';ConfigPath='C:\DBBackup\Instances\ASSESSORIA\config.psd1';Jobs=@([pscustomobject]@{Id='database'});Schedule=@{Tasks=@(@{Name='daily';Job='database';At='19:00'})}}
        $plan=@(Get-TestPlan $c)
        Invoke-DBSchedulePlan -Configuration $c -Plan $plan
        $script:Requested | Where-Object { $_.Length -gt 1 -and $_.EndsWith('\') } | Should -BeNullOrEmpty
        $script:Registered | Should -Be @('\DBBackup|ASSESSORIA-daily')
        ConvertTo-DBSchedulerFolderPath '\' | Should -Be '\'
    }
    It 'refuses to change a task that is not named after the instance' {
        $c=@{InstanceName='ASSESSORIA'}
        $plan=@([pscustomobject]@{Action='Remove';Name='MULTICOPIAS-daily';Definition=$null})
        { Invoke-DBSchedulePlan -Configuration $c -Plan $plan } | Should -Throw '*not named after instance*'
        $script:Requested.Count | Should -Be 0
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
Describe 'Guided setup' {
    BeforeEach {
        $script:Instances=Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:Config=Join-Path $script:Instances 'estoque/config.psd1'
        Mock Set-Acl {} -ModuleName Runtime
        Mock Set-Acl {} -ModuleName Setup
        Mock Out-Host {} -ModuleName Setup
        Mock Write-Warning {} -ModuleName Setup
        $script:Tools=Join-Path $TestDrive 'tools'
        $null=New-Item -ItemType Directory $script:Tools -Force
        foreach ($name in 'mysql.exe','mysqldump.exe','7z.exe','age.exe','rclone.exe','dbbackup.exe') { Set-Content (Join-Path $script:Tools $name) 'x' }
        $script:Prompts=[Collections.Generic.List[string]]::new()
        $script:Answers=@{}
        Mock Read-Host {
            param($Prompt, [switch] $AsSecureString)
            $script:Prompts.Add([string] $Prompt)
            if ($AsSecureString) { $secure=[Security.SecureString]::new(); foreach ($ch in 'segredo'.ToCharArray()) { $secure.AppendChar($ch) }; return $secure }
            foreach ($key in $script:Answers.Keys) { if ([string] $Prompt -like $key) { $value=$script:Answers[$key]; if ($value -is [Collections.Generic.Queue[string]]) { return $value.Dequeue() }; return $value } }
            ''
        } -ModuleName Setup
    }
    It 'asks for bucket and prefix separately and never suggests placeholders' {
        $null=Initialize-DBInstance -ConfigPath $script:Config -Provider MySQL -InstanceName estoque -TemplateRoot "$script:Repo/src/Templates" -InstancesRoot $script:Instances
        $script:Answers=@{
            'Executavel mysql.exe*'=(Join-Path $script:Tools 'mysql.exe'); 'Executavel mysqldump.exe*'=(Join-Path $script:Tools 'mysqldump.exe')
            'Executavel 7z.exe*'=(Join-Path $script:Tools '7z.exe'); 'Executavel age.exe*'=(Join-Path $script:Tools 'age.exe'); 'Executavel rclone.exe*'=(Join-Path $script:Tools 'rclone.exe')
            'Nome do banco MySQL*'=[Collections.Generic.Queue[string]]::new([string[]]@('', 'a_estoque'))
            'Bucket S3*'=[Collections.Generic.Queue[string]]::new([string[]]@('Bucket_Invalido', 'assessoriatech-backups-seven-prod'))
            'Prefixo*'='ASSESSORIA/'
            'Horario*'='02:30'
        }
        Set-DBInteractiveConfiguration $script:Config
        $c=Read-DBConfiguration $script:Config
        $c.Database.Name | Should -Be 'a_estoque'
        $c.Storage.RemoteRoot | Should -BeExactly 's3:assessoriatech-backups-seven-prod/ASSESSORIA'
        @(Get-DBScheduleTask $c)[0].At | Should -Be '02:30'
        $script:Prompts | Where-Object { $_ -match 'REPLACE_' } | Should -BeNullOrEmpty
        @($script:Prompts | Where-Object { $_ -like 'Nome do banco MySQL*' }).Count | Should -Be 2
    }
    It 're-asks for a missing executable instead of failing at the end' {
        $null=Initialize-DBInstance -ConfigPath $script:Config -Provider MySQL -InstanceName estoque -TemplateRoot "$script:Repo/src/Templates" -InstancesRoot $script:Instances
        # Ordered: the specific pattern must win over the generic 'Executavel*'.
        $script:Answers=[ordered]@{
            'Executavel mysql.exe*'=[Collections.Generic.Queue[string]]::new([string[]]@((Join-Path $script:Tools 'missing.exe'), (Join-Path $script:Tools 'mysql.exe')))
            'Executavel*'=(Join-Path $script:Tools '7z.exe'); 'Nome do banco*'='db'; 'Bucket S3*'='bucket-x'; 'Prefixo*'='/'; 'Horario*'=''
        }
        Set-DBInteractiveConfiguration $script:Config
        (Read-DBConfiguration $script:Config).Tools.MySql | Should -Be (Join-Path $script:Tools 'mysql.exe')
        (Read-DBConfiguration $script:Config).Storage.RemoteRoot | Should -BeExactly 's3:bucket-x'
        Should -Invoke Write-Warning -ModuleName Setup -Times 1 -Exactly
    }
    It 'asks MySQL host and port without SQL Anywhere hints and writes a least-privilege rclone config' {
        $null=Initialize-DBInstance -ConfigPath $script:Config -Provider MySQL -InstanceName estoque -TemplateRoot "$script:Repo/src/Templates" -InstancesRoot $script:Instances
        $c=Read-DBConfiguration $script:Config
        Set-Content $c.Encryption.RecipientsFile ('age1'+('q'*58))
        $script:Answers=@{ 'Host do servidor MySQL*'='db01'; 'Porta MySQL*'='3307'; 'Usuario*'='backup_seven'; 'Provedor S3*'='AWS'; 'Access key ID*'='AKIDTEST'; 'Regiao*'='' }
        Initialize-DBSecret $c
        $script:Prompts | Where-Object { $_ -match 'SQL Anywhere|Endpoint' } | Should -BeNullOrEmpty
        $cnf=Get-Content $c.Database.DefaultsExtraFile -Raw
        $cnf | Should -Match 'host="db01"'
        $cnf | Should -Match 'port=3307'
        $rclone=Get-Content $c.Storage.ConfigPath -Raw
        $rclone | Should -Match '(?m)^no_check_bucket = true$'
        $rclone | Should -Match '(?m)^region = sa-east-1$'
        $rclone | Should -Not -Match 'endpoint'
    }
    It 'writes SERVER for a local SQL Anywhere server and HOST for a network one' {
        $null=Initialize-DBInstance -ConfigPath $script:Config -Provider SQLAnywhere -InstanceName estoque -TemplateRoot "$script:Repo/src/Templates" -InstancesRoot $script:Instances
        Set-Content $script:Config ((Get-Content $script:Config -Raw).Replace('REPLACE_DATABASE','demo'))
        $c=Read-DBConfiguration $script:Config
        foreach ($file in @($c.Storage.ConfigPath,$c.Encryption.RecipientsFile)) { Set-Content $file 'preserve' }
        $script:Answers=@{ 'Servidor em rede*'=''; 'Nome do servidor local*'='srv_demo'; 'Usuario*'='dba' }
        Initialize-DBSecret $c
        $connection=Read-DBSqlConnection $c.Database.ConnectionOptionsFile
        $connection.SERVER | Should -Be 'srv_demo'
        $connection.ContainsKey('HOST') | Should -BeFalse
        Remove-Item $c.Database.ConnectionOptionsFile
        $script:Answers=@{ 'Servidor em rede*'='10.0.0.5:2638'; 'Usuario*'='dba' }
        Initialize-DBSecret $c
        (Read-DBSqlConnection $c.Database.ConnectionOptionsFile).HOST | Should -Be '10.0.0.5:2638'
    }
    It 'lists visible databases when the configured MySQL database is not reachable' {
        $null=Initialize-DBInstance -ConfigPath $script:Config -Provider MySQL -InstanceName estoque -TemplateRoot "$script:Repo/src/Templates" -InstancesRoot $script:Instances
        Set-Content $script:Config ((Get-Content $script:Config -Raw).Replace('REPLACE_DATABASE','estoque_errado'))
        Mock Invoke-DBTool {
            param($Arguments)
            if (($Arguments -join ' ') -match 'SELECT 1') { return [pscustomobject]@{ExitCode=1;StdOut='';StdErr="ERROR 1049 (42000): Unknown database 'estoque_errado'"} }
            [pscustomobject]@{ExitCode=0;StdOut="information_schema`na_estoque`nmysql";StdErr=''}
        } -ModuleName Setup
        $result=Test-DBDatabaseConnection -Configuration (Read-DBConfiguration $script:Config)
        $result.Ok | Should -BeFalse
        $result.Message | Should -Match 'Bancos visiveis: a_estoque$'
    }
    It 'stops before applying when a connection check fails and the operator declines' {
        Mock Test-DBDatabaseConnection { [pscustomobject]@{Ok=$true;Message='ok'} } -ModuleName Setup
        Mock Test-DBStorageAccess { [pscustomobject]@{Ok=$false;Message='AccessDenied'} } -ModuleName Setup
        $c=@{Tools=@{Rclone='rclone.exe'};Storage=@{ConfigPath='rclone.conf';RemoteRoot='s3:b/p'}}
        $script:Answers=@{ 'Testar agora*'='s'; 'Algum teste falhou*'='' }
        Invoke-DBConnectionCheck $c | Should -BeFalse
        $script:Answers=@{ 'Testar agora*'='n' }
        Invoke-DBConnectionCheck $c | Should -BeTrue
        Should -Invoke Test-DBStorageAccess -ModuleName Setup -Times 1 -Exactly
    }
    It 'summarizes destination, tasks and the next step' {
        $null=Initialize-DBInstance -ConfigPath $script:Config -Provider MySQL -InstanceName estoque -TemplateRoot "$script:Repo/src/Templates" -InstancesRoot $script:Instances
        Set-Content $script:Config ((Get-Content $script:Config -Raw).Replace('REPLACE_DATABASE','a_estoque').Replace('s3:REPLACE_BUCKET','s3:bucket-x/ASSESSORIA'))
        $c=Read-DBConfiguration $script:Config
        Set-Content $c.Encryption.RecipientsFile @(('age1'+('q'*58)), ('age1'+('p'*58)))
        $text=(Get-DBSetupSummary -Configuration $c -RegisteredTasks @('estoque-database-daily') -PwshPath 'C:\pwsh.exe' -ScriptPath 'C:\DBBackup\Backup.ps1') -join "`n"
        $text | Should -Match 's3:bucket-x/ASSESSORIA/<trabalho>/aaaa/mm/dd/'
        $text | Should -Match 'Destinatarios age: 2'
        $text | Should -Match '\\DBBackup\\estoque-database-daily - Daily 19:00 \(registrada\)'
        $text | Should -Match '-Job database'
    }
}

