BeforeAll {
    $script:Repo=Split-Path -Parent $PSScriptRoot
    Import-Module "$script:Repo/src/App/Modules/Core/Configuration.psm1"
    Import-Module "$script:Repo/src/App/Modules/Core/Runtime.psm1"
    Import-Module "$script:Repo/src/App/Modules/Core/Schedule.psm1"
    Import-Module "$script:Repo/src/App/Modules/Core/Setup.psm1"
    . (Join-Path $PSScriptRoot 'V1.TestSupport.ps1')
    Import-Module "$script:Repo/src/App/Modules/Providers/SQLAnywhere/SQLAnywhere.psm1"
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
        $script:C=@{InstanceName='MySQL';ConfigPath='C:\DBBackup\Instances\MySQL\config.psd1';Jobs=@([pscustomobject]@{Id='database'},[pscustomobject]@{Id='files'});Schedule=@{Tasks=@(@{Name='daily';Jobs=@('database');At='19:00'})}}
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
        $other=@{InstanceName='SQLAnywhere';ConfigPath='C:\DBBackup\Instances\SQLAnywhere\config.psd1';Jobs=@([pscustomobject]@{Id='database'});Schedule=@{Tasks=@(@{Name='daily';Jobs=@('database');At='02:00'})}}
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
    It 'runs every job of a task in one execution' {
        $script:C.Schedule.Tasks=@(@{Name='daily';Jobs=@('database','files');At='19:00'})
        (New-TestDefinition $script:C).Arguments | Should -Match '-Job database,files$'
        $script:C.Schedule.Tasks=@(@{Name='daily';Jobs=@('database','database');At='19:00'})
        { Get-DBScheduleTask $script:C } | Should -Throw '*repeats a job*'
    }
    It 'validates weekly and monthly calendars with arbitrary job IDs' {
        $script:C.Schedule.Tasks=@(@{Name='weekly';Jobs=@('files');At='03:00';Frequency='Weekly';Days=@('Saturday')},@{Name='monthly';Jobs=@('database','files');At='04:00';Frequency='Monthly';DaysOfMonth=@(1,'Last')})
        $tasks=@(Get-DBScheduleTask $script:C)
        $tasks.Count | Should -Be 2
        Get-DBScheduleNextRun -Tasks $tasks -Job files -After ([datetime]'2026-11-17T00:00:00') | Should -Be ([datetime]'2026-11-21T03:00:00')
        $script:C.Schedule.Tasks[0].Jobs=@('unknown')
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
        $c=@{InstanceName='ASSESSORIA';ConfigPath='C:\DBBackup\Instances\ASSESSORIA\config.psd1';Jobs=@([pscustomobject]@{Id='database'});Schedule=@{Tasks=@(@{Name='daily';Jobs=@('database');At='19:00'})}}
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
Describe 'Guided setup 2.0' {
    BeforeEach {
        $script:Instances=Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:Templates="$script:Repo/src/App/Templates"
        Mock Set-Acl {} -ModuleName Runtime
        Mock Set-Acl {} -ModuleName Setup
        Mock Out-Host {} -ModuleName Setup
        Mock Write-Warning {} -ModuleName Setup
        $script:Tools=Join-Path $TestDrive 'tools'
        $null=New-Item -ItemType Directory $script:Tools -Force
        foreach ($name in 'mysql.exe','mysqldump.exe','7z.exe','age.exe','rclone.exe','dbbackup.exe') { Set-Content (Join-Path $script:Tools $name) 'x' }
        $script:Docs=Join-Path $TestDrive 'docs'
        $null=New-Item -ItemType Directory $script:Docs -Force
        $script:Age='age1'+('q'*58)
        $script:Prompts=[Collections.Generic.List[string]]::new()
        $script:Answers=[ordered]@{}
        Mock Read-Host {
            param($Prompt, [switch] $AsSecureString)
            $script:Prompts.Add([string] $Prompt)
            # A flow that keeps asking must fail the test, not hang it.
            if ($script:Prompts.Count -gt 200) { throw "Too many prompts; last: $Prompt" }
            if ($AsSecureString) { $secure=[Security.SecureString]::new(); foreach ($ch in 'segredo'.ToCharArray()) { $secure.AppendChar($ch) }; return $secure }
            foreach ($key in $script:Answers.Keys) {
                if ([string] $Prompt -like $key) {
                    $value=$script:Answers[$key]
                    if ($value -is [Collections.Generic.Queue[string]]) { if ($value.Count -eq 0) { throw "No more answers for $key" }; return $value.Dequeue() }
                    return $value
                }
            }
            ''
        } -ModuleName Setup
        function New-AnswerSet([Collections.Specialized.OrderedDictionary] $Extra) {
            $base=[ordered]@{
                'Executavel 7z.exe*'=(Join-Path $script:Tools '7z.exe'); 'Executavel age.exe*'=(Join-Path $script:Tools 'age.exe'); 'Executavel rclone.exe*'=(Join-Path $script:Tools 'rclone.exe')
                'Executavel mysql.exe*'=(Join-Path $script:Tools 'mysql.exe'); 'Executavel mysqldump.exe*'=(Join-Path $script:Tools 'mysqldump.exe'); 'Executavel dbbackup.exe*'=(Join-Path $script:Tools 'dbbackup.exe')
                'Provedor S3*'='AWS'; 'Access key ID*'='AKIDTEST'; 'Regiao*'=''; 'Destinatarios age*'=$script:Age
            }
            # Returned, not assigned here: a function's $script: scope is not the
            # scope the Read-Host mock reads.
            $merged=[ordered]@{}
            foreach ($key in $Extra.Keys) { $merged[$key]=$Extra[$key] }
            foreach ($key in $base.Keys) { if (-not $merged.Contains($key)) { $merged[$key]=$base[$key] } }
            return $merged
        }
        # The comma keeps PowerShell from enumerating the queue on output.
        function Q([string[]] $Items) { return ,([Collections.Generic.Queue[string]]::new($Items)) }
    }
    It 'creates an instance with a MySQL job and a directory job grouped in one daily task' {
        $script:Answers=New-AnswerSet ([ordered]@{
            'Adicionar job*'=(Q @('1','3',''))
            'Nome do banco MySQL*'='a_estoque'
            'Identificador do job*'=(Q @('seven',''))
            'Host do servidor MySQL*'=''; 'Porta MySQL*'=''; 'Usuario de backup*'='backup_seven'
            'Bucket S3*'=(Q @('Bucket_Invalido','assessoriatech-backups-seven-prod',''))
            'Prefixo*'=''
            'Pasta a copiar*'=$script:Docs
            'Horarios diarios*'=(Q @('19:00','19:00'))
        })
        $path=Invoke-DBInteractiveSetup -InstancesRoot $script:Instances -TemplateRoot $script:Templates -InstanceName 'assessoria'
        $c=Read-DBConfiguration $path
        @($c.Jobs.Id) | Should -Be @('seven','docs')
        $c.Jobs[0].Provider | Should -Be 'MySQL'
        $c.Jobs[0].Database | Should -Be 'a_estoque'
        $c.Jobs[0].Destination | Should -BeExactly 's3:assessoriatech-backups-seven-prod/ASSESSORIA/seven'
        $c.Jobs[1].Provider | Should -Be 'Directory'
        $c.Jobs[1].Destination | Should -BeExactly 's3:assessoriatech-backups-seven-prod/ASSESSORIA/docs'
        $tasks=@(Get-DBScheduleTask $c)
        $tasks.Count | Should -Be 1
        $tasks[0].RegisteredName | Should -Be 'assessoria-diario-1900'
        @($tasks[0].Jobs) | Should -Be @('seven','docs')
        Get-Content $c.Jobs[0].CredentialFile -Raw | Should -Match 'user="backup_seven"'
        Get-Content $c.Storage.ConfigPath -Raw | Should -Match '(?m)^no_check_bucket = true$'
        $c.Paths.CompletedRoot | Should -Be (Join-Path (Split-Path $script:Instances) 'Completed/assessoria')
        $c.Paths.LogRoot | Should -Be (Join-Path (Split-Path $script:Instances) 'Logs/assessoria')
        # The job menu lists every provider; no other MySQL prompt mentions SQL Anywhere.
        $script:Prompts | Where-Object { $_ -notlike 'Adicionar job*' -and $_ -match 'REPLACE_|SQL Anywhere' } | Should -BeNullOrEmpty
        @($script:Prompts | Where-Object { $_ -like 'Bucket S3*' }).Count | Should -Be 3
        Should -Invoke Write-Warning -ModuleName Setup -Times 1 -Exactly
    }
    It 'reuses secrets found in the instance folder and keeps the 1.x config aside' {
        $secrets=Join-Path $script:Instances 'assessoria/Secrets'
        $null=New-Item -ItemType Directory $secrets -Force
        Set-Content (Join-Path $secrets 'mysql.cnf') "[client]`nuser=old"
        Set-Content (Join-Path $secrets 'rclone.conf') "[aws]`ntype = s3"
        Set-Content (Join-Path $secrets 'recipients.txt') $script:Age
        Set-Content (Join-Path $script:Instances 'assessoria/config.psd1') "@{ SchemaVersion = 1; InstanceName = 'ASSESSORIA' }"
        $script:Answers=New-AnswerSet ([ordered]@{
            'Adicionar job*'=(Q @('1','')); 'Adicionar backup de diretorio*'=''
            'Nome do banco MySQL*'='a_estoque'; 'Identificador do job*'=''
            'Bucket S3*'='bucket-x'; 'Prefixo*'='ASSESSORIA'; 'Horarios diarios*'='02:30'
        })
        $path=Invoke-DBInteractiveSetup -InstancesRoot $script:Instances -TemplateRoot $script:Templates -InstanceName 'assessoria'
        $c=Read-DBConfiguration $path
        $c.Jobs[0].CredentialFile | Should -Be (Join-Path $secrets 'mysql.cnf')
        $c.Jobs[0].Id | Should -Be 'a_estoque'
        $c.Jobs[0].RemoteRoot | Should -BeExactly 'aws:bucket-x/ASSESSORIA'
        Get-Content (Join-Path $secrets 'mysql.cnf') -Raw | Should -Match 'user=old'
        Test-Path (Join-Path $script:Instances 'assessoria/config.v1.psd1') | Should -BeTrue
        $script:Prompts | Where-Object { $_ -like 'Access key*' -or $_ -like 'Host do servidor*' -or $_ -like 'Destinatarios*' } | Should -BeNullOrEmpty
        @($script:Prompts | Where-Object { $_ -like 'Encontrado Secrets*' }).Count | Should -Be 3
        @(Get-DBScheduleTask $c)[0].At | Should -Be '02:30'
    }
    It 'replaces a secret the operator declines and keeps the previous one as .old' {
        $secrets=Join-Path $script:Instances 'assessoria/Secrets'
        $null=New-Item -ItemType Directory $secrets -Force
        Set-Content (Join-Path $secrets 'rclone.conf') "[s3]`nold = 1"
        $script:Answers=New-AnswerSet ([ordered]@{
            'Encontrado Secrets\rclone.conf*'='n'
            'Adicionar job*'=(Q @('3','')); 'Pasta a copiar*'=$script:Docs; 'Identificador do job*'=''
            'Bucket S3*'='bucket-x'; 'Prefixo*'=''; 'Horarios diarios*'=''
        })
        $path=Invoke-DBInteractiveSetup -InstancesRoot $script:Instances -TemplateRoot $script:Templates -InstanceName 'assessoria'
        Get-Content (Join-Path $secrets 'rclone.conf.old') -Raw | Should -Match 'old = 1'
        Get-Content (Join-Path $secrets 'rclone.conf') -Raw | Should -Match 'access_key_id = AKIDTEST'
        (Read-DBConfiguration $path).Jobs[0].Provider | Should -Be 'Directory'
    }
    It 'asks about directory backup when only database jobs were added' {
        $script:Answers=New-AnswerSet ([ordered]@{
            'Adicionar job*'=(Q @('2','','')); 'Adicionar backup de diretorio*'='s'
            'Nome do banco SQL Anywhere*'='contabil'; 'Identificador do job*'=(Q @('dominio','arquivos'))
            'Servidor em rede*'=''; 'Nome do servidor local*'='srv_dominio'; 'Usuario de backup*'='dba'
            'Pasta a copiar*'=$script:Docs
            'Bucket S3*'=(Q @('bucket-dominio','bucket-arquivos')); 'Prefixo*'=''; 'Horarios diarios*'=(Q @('19:00','22:00'))
        })
        $path=Invoke-DBInteractiveSetup -InstancesRoot $script:Instances -TemplateRoot $script:Templates -InstanceName 'assessoria'
        $c=Read-DBConfiguration $path
        @($c.Jobs.Id) | Should -Be @('dominio','arquivos')
        (Read-DBSqlConnection $c.Jobs[0].CredentialFile).SERVER | Should -Be 'srv_dominio'
        @(Get-DBScheduleTask $c).Count | Should -Be 2
        @($script:Prompts | Where-Object { $_ -like 'Adicionar backup de diretorio*' }).Count | Should -Be 1
    }
    It 'reapplies an existing 2.0 instance without asking anything else' {
        $instance=Join-Path $script:Instances 'assessoria'
        $null=New-Item -ItemType Directory (Join-Path $instance 'Secrets') -Force
        Set-Content (Join-Path $instance 'config.psd1') (Get-DBTestConfigText -RemoteRoot 's3:bucket-x/ASSESSORIA' -InstanceName 'assessoria')
        $script:Answers=New-AnswerSet ([ordered]@{ 'A instancia assessoria ja existe*'='' })
        $path=Invoke-DBInteractiveSetup -InstancesRoot $script:Instances -TemplateRoot $script:Templates -InstanceName 'assessoria'
        $path | Should -Be (Join-Path $instance 'config.psd1')
        $script:Prompts.Count | Should -Be 1
    }
    It 'refuses a job destination already used by another instance' {
        $other=Join-Path $script:Instances 'outra'
        $null=New-Item -ItemType Directory $other -Force
        Set-Content (Join-Path $other 'config.psd1') (Get-DBTestConfigText -RemoteRoot 's3:bucket-x/ASSESSORIA' -InstanceName 'outra')
        $script:Answers=New-AnswerSet ([ordered]@{
            'Adicionar job*'=(Q @('3','')); 'Pasta a copiar*'=$script:Docs; 'Identificador do job*'='database'
            'Bucket S3*'='bucket-x'; 'Prefixo*'='ASSESSORIA'; 'Horarios diarios*'=''; 'Adicionar backup de diretorio*'=''
        })
        { Invoke-DBInteractiveSetup -InstancesRoot $script:Instances -TemplateRoot $script:Templates -InstanceName 'assessoria' } | Should -Throw '*remote destination*'
        Test-Path (Join-Path $script:Instances 'assessoria/config.psd1') | Should -BeFalse
    }
    It 'serializes literal values without interpreting embedded PowerShell' {
        $path=Join-Path $TestDrive 'roundtrip.psd1'
        $value=@{Name="O'Brien";Literal='$(should-never-run)';Enabled=$true;Items=@(1,'Last');Jobs=@([ordered]@{Id='a';Provider='Directory'})}
        Set-Content $path (ConvertTo-DBDataLiteral $value)
        $copy=Import-PowerShellDataFile $path
        $copy.Name | Should -Be "O'Brien"
        $copy.Literal | Should -Be '$(should-never-run)'
        $copy.Items | Should -Be @(1,'Last')
        $copy.Jobs[0].Id | Should -Be 'a'
    }
}
Describe 'Apply, diagnostics and summary' {
    BeforeEach {
        $script:Instances=Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:Config=Join-Path $script:Instances 'assessoria/config.psd1'
        $null=New-Item -ItemType Directory (Join-Path $script:Instances 'assessoria/Secrets') -Force
        Set-Content $script:Config ((Get-DBTestConfigText -RemoteRoot 's3:bucket-x/ASSESSORIA' -InstanceName 'assessoria') -replace "(?m)^\s*Paths = .*\r?\n", '')
        Set-Content (Join-Path $script:Instances 'assessoria/Secrets/mysql.cnf') "[client]`nuser=u"
        Set-Content (Join-Path $script:Instances 'assessoria/Secrets/rclone.conf') '[s3]'
        Set-Content (Join-Path $script:Instances 'assessoria/Secrets/recipients.txt') @(('age1'+('q'*58)), ('age1'+('p'*58)))
        Mock Set-Acl {} -ModuleName Runtime
        Mock Set-Acl {} -ModuleName Setup
        Mock Out-Host {} -ModuleName Setup
    }
    It 'plans without creating state directories, modifying config or applying tasks' {
        $before=(Get-FileHash $script:Config).Hash
        Mock Get-DBSchedulerSnapshot { @() } -ModuleName Setup
        Mock Invoke-DBSchedulePlan { throw 'Unexpected task mutation' } -ModuleName Setup
        $plan=@(Invoke-DBConfigurationApply -Configuration (Read-DBConfiguration $script:Config) -InstancesRoot $script:Instances -ScriptPath 'C:\DBBackup\App\Backup.ps1' -PwshPath 'C:\pwsh.exe' -PlanOnly)
        $plan.Action | Should -Be Create
        $plan.Name | Should -Be 'assessoria-database-daily'
        (Get-FileHash $script:Config).Hash | Should -Be $before
        Test-Path (Join-Path (Split-Path $script:Instances) 'Completed') | Should -BeFalse
        Should -Invoke Invoke-DBSchedulePlan -ModuleName Setup -Times 0 -Exactly
    }
    It 'performs local diagnostics without changing instance files or scheduler state' {
        $c=Read-DBConfiguration $script:Config
        $before=@(Get-ChildItem (Split-Path $script:Config) -Recurse -File | Get-FileHash | ForEach-Object Hash)
        Mock Test-DBPrivateAcl {} -ModuleName Setup
        Mock Assert-DBBackupDependency {} -ModuleName Setup
        Mock Get-DBSchedulerSnapshot { throw 'Diagnostics must not inspect scheduler.' } -ModuleName Setup
        (Test-DBInstance $c $script:Instances).Status | Should -Be LOCAL_CHECKS_OK
        @(Get-ChildItem (Split-Path $script:Config) -Recurse -File | Get-FileHash | ForEach-Object Hash) | Should -Be $before
        Should -Invoke Test-DBPrivateAcl -ModuleName Setup -Times 3 -Exactly
    }
    It 'lists visible databases when the configured MySQL database is not reachable' {
        Mock Invoke-DBTool {
            param($Arguments)
            if (($Arguments -join ' ') -match 'SELECT 1') { return [pscustomobject]@{ExitCode=1;StdOut='';StdErr="ERROR 1049 (42000): Unknown database 'testdb'"} }
            [pscustomobject]@{ExitCode=0;StdOut="information_schema`na_estoque`nmysql";StdErr=''}
        } -ModuleName Setup
        $c=Read-DBConfiguration $script:Config
        $result=Test-DBDatabaseConnection -Configuration $c -Job $c.Jobs[0]
        $result.Ok | Should -BeFalse
        $result.Message | Should -Match 'Bancos visiveis: a_estoque$'
    }
    It 'stops before applying when a connection check fails and the operator declines' {
        Mock Test-DBDatabaseConnection { [pscustomobject]@{Ok=$true;Message='ok'} } -ModuleName Setup
        Mock Test-DBStorageAccess { [pscustomobject]@{Ok=$false;Message='AccessDenied'} } -ModuleName Setup
        $script:Replies=[ordered]@{ 'Testar agora*'='s'; 'Algum teste falhou*'='' }
        Mock Read-Host { param($Prompt) foreach ($key in $script:Replies.Keys) { if ($Prompt -like $key) { return $script:Replies[$key] } }; '' } -ModuleName Setup
        $c=Read-DBConfiguration $script:Config
        Invoke-DBConnectionCheck $c | Should -BeFalse
        $script:Replies=[ordered]@{ 'Testar agora*'='n' }
        Invoke-DBConnectionCheck $c | Should -BeTrue
        Should -Invoke Test-DBStorageAccess -ModuleName Setup -Times 1 -Exactly
    }
    It 'summarizes jobs, destinations, tasks and the next step' {
        $c=Read-DBConfiguration $script:Config
        $text=(Get-DBSetupSummary -Configuration $c -RegisteredTasks @('assessoria-database-daily') -PwshPath 'C:\pwsh.exe' -ScriptPath 'C:\DBBackup\App\Backup.ps1') -join "`n"
        $text | Should -Match 'Job database: MySQL, banco testdb -> s3:bucket-x/ASSESSORIA/database/aaaa/mm/dd/'
        $text | Should -Match 'Destinatarios age: 2'
        $text | Should -Match '\\DBBackup\\assessoria-database-daily - Daily 19:00, jobs database \(registrada\)'
        $text | Should -Match '-All'
    }
}
