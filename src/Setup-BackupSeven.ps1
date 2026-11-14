#requires -Version 7.0

<#
.SYNOPSIS
Configura o BackupSeven ou aplica a configuracao existente.

.DESCRIPTION
Sem parametros (Setup.bat): pergunta os dados da instalacao, com os valores
atuais como padrao, e grava somente o que mudou em config.psd1 e Secrets.
Depois aplica a configuracao.

Com -Apply (Aplicar-Configuracao.bat): nao pergunta dados; aplica o
config.psd1 como esta.

Aplicar a configuracao significa: remover a marca de arquivo baixado da
internet, criar as pastas, restringir Secrets a SYSTEM e Administradores,
testar MySQL, S3 e a pasta do Grafana Alloy e reconciliar as tarefas
agendadas com a secao Schedule (pasta protegida \BackupSeven\ do Agendador).
As alteracoes nas tarefas sao mostradas e confirmadas antes de aplicar.
#>
[CmdletBinding()]
param(
    [switch] $Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$configPath = Join-Path $root 'config.psd1'
$secretsPath = Join-Path $root 'Secrets'
$mysqlConfigPath = Join-Path $secretsPath 'mysql-backup.cnf'
$rcloneConfigPath = Join-Path $secretsPath 'rclone.conf'
$entryScript = Join-Path $root 'Backup-Seven.ps1'
$defaultTextfile = 'C:\ProgramData\GrafanaLabs\Alloy\textfile\backup'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$failures = [System.Collections.Generic.List[string]]::new()
$notices = [System.Collections.Generic.List[string]]::new()

function Write-Step([string] $Text) { Write-Output ''; Write-Output "== $Text" }
function Write-Check([bool] $Ok, [string] $Text) {
    if ($Ok) { Write-Output "  [ OK ] $Text" } else { Write-Output "  [ERRO] $Text"; $failures.Add($Text) }
}
function Write-Notice([string] $Text) { Write-Output "  [AVISO] $Text"; $notices.Add($Text) }

function Read-Value([string] $Prompt, [string] $Default, [string] $Pattern = '.+') {
    while ($true) {
        $suffix = if ([string]::IsNullOrEmpty($Default)) { '' } else { " [$Default]" }
        $value = Read-Host "$Prompt$suffix"
        if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }
        if (-not [string]::IsNullOrWhiteSpace($value) -and $value.Trim() -match $Pattern) { return $value.Trim() }
        Write-Output '  Valor invalido.'
    }
}

function Read-Secret([string] $Prompt) {
    while ($true) {
        # Entrada redirecionada (automacao): leitura simples, sem mascara.
        if ([Console]::IsInputRedirected) {
            $plain = Read-Host $Prompt
        }
        else {
            $secure = Read-Host $Prompt -AsSecureString
            $plain = [System.Net.NetworkCredential]::new('', $secure).Password
        }
        if (-not [string]::IsNullOrEmpty($plain)) { return $plain }
        Write-Output '  Valor obrigatorio.'
    }
}

function Read-YesNo([string] $Prompt, [bool] $Default) {
    $hint = if ($Default) { '[S/n]' } else { '[s/N]' }
    $answer = Read-Host "$Prompt $hint"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim() -match '^(s|sim|y|yes)$'
}

function Read-ExistingPath([string] $Prompt, [string] $Default, [string] $PathType) {
    while ($true) {
        $value = Read-Value $Prompt $Default
        if (Test-Path -LiteralPath $value -PathType $PathType) { return $value }
        Write-Output "  Nao encontrado: $value"
    }
}

function Get-Setting([object] $Section, [string] $Key, [object] $Default) {
    if ($Section -is [System.Collections.IDictionary] -and $Section.Contains($Key) -and $null -ne $Section[$Key]) {
        return $Section[$Key]
    }
    return $Default
}

function Test-Template([string] $Path) {
    return -not (Test-Path -LiteralPath $Path -PathType Leaf) -or
        (Get-Content -LiteralPath $Path -Raw) -match 'REPLACE_WITH_'
}

function ConvertTo-Psd1([string] $Value) { return "'" + $Value.Replace("'", "''") + "'" }
function ConvertTo-OptionValue([string] $Value) { return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"' }

# Valor de configuracao em sintaxe psd1. Hashtables so de valores simples (ou
# listas simples) ficam em uma linha; listas de hashtables, uma por linha.
function ConvertTo-Psd1Value([object] $Value, [int] $Indent, [switch] $Inline) {
    $pad = ' ' * $Indent
    if ($null -eq $Value) { return '$null' }
    if ($Value -is [bool]) { return '$' + $Value.ToString().ToLowerInvariant() }
    if ($Value -is [string]) { return ConvertTo-Psd1 $Value }
    if ($Value -is [System.ValueType]) { return ([System.IConvertible] $Value).ToString([System.Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -is [System.Collections.IDictionary]) {
        $order = @('Name', 'Mode', 'Frequency', 'Days', 'DaysOfMonth', 'At', 'Enabled')
        $keys = @($Value.Keys | Sort-Object { $i = [array]::IndexOf($order, [string] $_); if ($i -lt 0) { 100 } else { $i } }, { [string] $_ })
        $nested = @($keys | Where-Object {
                $item = $Value[$_]
                $item -is [System.Collections.IDictionary] -or
                ($item -is [array] -and @($item | Where-Object { $_ -is [System.Collections.IDictionary] -or $_ -is [array] }).Count -gt 0)
            }).Count -gt 0
        if ($Inline -or -not $nested) {
            return '@{ ' + (($keys | ForEach-Object { "$_ = $(ConvertTo-Psd1Value $Value[$_] 0 -Inline)" }) -join '; ') + ' }'
        }
        $lines = $keys | ForEach-Object { "$pad    $_ = $(ConvertTo-Psd1Value $Value[$_] ($Indent + 4))" }
        return "@{`n" + ($lines -join "`n") + "`n$pad}"
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value)
        if ($Inline) {
            return '@(' + (($items | ForEach-Object { ConvertTo-Psd1Value $_ 0 -Inline }) -join ', ') + ')'
        }
        $lines = $items | ForEach-Object { "$pad    $(ConvertTo-Psd1Value $_ ($Indent + 4))" }
        return "@(`n" + ($lines -join "`n") + "`n$pad)"
    }
    return ConvertTo-Psd1 ([string] $Value)
}

# Forma comparavel de uma configuracao: chaves ordenadas, sem formatacao.
function ConvertTo-CanonicalJson([object] $Value) {
    function ConvertTo-CanonicalValue([object] $Item) {
        if ($Item -is [System.Collections.IDictionary]) {
            $ordered = [ordered]@{}
            foreach ($key in @($Item.Keys | Sort-Object)) { $ordered[$key] = ConvertTo-CanonicalValue $Item[$key] }
            return $ordered
        }
        if ($Item -is [array]) { return , @($Item | ForEach-Object { ConvertTo-CanonicalValue $_ }) }
        return $Item
    }
    return (ConvertTo-CanonicalValue $Value) | ConvertTo-Json -Depth 10 -Compress
}

# Remove a marca de arquivo baixado da internet (Zone.Identifier), que faz a
# politica de execucao recusar scripts e modulos nao assinados.
function Unblock-PackageFile {
    if (-not $IsWindows) { return 0 }
    $count = 0
    foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File) {
        if (Get-Item -LiteralPath $file.FullName -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue) {
            Unblock-File -LiteralPath $file.FullName
            $count++
        }
    }
    return $count
}

# SYSTEM e Administradores com controle total, sem heranca. Aplica somente se
# a ACL atual for diferente; devolve $true quando alterou.
function Set-PrivateAcl([string] $Path) {
    if (-not $IsWindows) { return $false }
    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $identity = [System.Security.Principal.SecurityIdentifier]::new($sid)
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                $identity, 'FullControl', $inherit, 'None', 'Allow'))
    }
    $current = (Get-Acl -LiteralPath $Path).GetSecurityDescriptorSddlForm('Access')
    if ($current -eq $acl.GetSecurityDescriptorSddlForm('Access')) { return $false }
    Set-Acl -LiteralPath $Path -AclObject $acl
    return $true
}

function Format-ScheduleTask([pscustomobject] $Task) {
    $when = switch ($Task.Frequency) {
        'Daily' { "diario as $($Task.At)" }
        'Weekly' { "semanal ($($Task.Days -join ', ')) as $($Task.At)" }
        'Monthly' { "mensal (dias $($Task.DaysOfMonth -join ', ')) as $($Task.At)" }
    }
    $state = if ($Task.Enabled) { '' } else { ', desativada' }
    return "$($Task.Name): $($Task.Mode), $when$state"
}

function Get-TaskScheduler {
    $service = New-Object -ComObject 'Schedule.Service'
    $service.Connect()
    return $service
}

# missing | unprotected | ok. Protegida = DACL protegida so com SYSTEM e
# Administradores (a forma do SDDL devolvido pode variar).
function Get-TaskFolderState {
    $name = (Get-SevenScheduleTaskFolder).Trim('\')
    $service = Get-TaskScheduler
    try { $folder = $service.GetFolder("\$name") } catch { return 'missing' }
    $sddl = [string] $folder.GetSecurityDescriptor(4)
    $aces = @([regex]::Matches($sddl, '\(([^)]*)\)') | ForEach-Object { $_.Groups[1].Value })
    $sids = @($aces | ForEach-Object { ($_ -split ';')[-1] } | Sort-Object -Unique)
    $allAllow = @($aces | Where-Object { -not $_.StartsWith('A;') }).Count -eq 0
    if ($sddl -match '^D:P' -and $allAllow -and ($sids -join ',') -eq 'BA,SY') { return 'ok' }
    return 'unprotected'
}

function Initialize-TaskFolder([string] $State) {
    $name = (Get-SevenScheduleTaskFolder).Trim('\')
    $security = Get-SevenScheduleTaskSecurity
    $service = Get-TaskScheduler
    if ($State -eq 'missing') {
        $null = $service.GetFolder('\').CreateFolder($name, $security)
    }
    elseif ($State -eq 'unprotected') {
        $service.GetFolder("\$name").SetSecurityDescriptor($security, 0)
    }
}

function Test-BackupSevenTask([object] $Task) {
    return @($Task.Actions | Where-Object { $_.PSObject.Properties['Arguments'] -and $_.Arguments -match 'Backup-Seven\.ps1' }).Count -gt 0
}

# Reconcilia o Agendador com a secao Schedule: cria, altera e remove tarefas
# na pasta \BackupSeven\ e remove tarefas do BackupSeven fora dela (versoes
# anteriores). Mostra o plano e pede confirmacao antes de alterar.
function Sync-Schedule([System.Collections.IDictionary] $Configuration) {
    Write-Step 'Tarefas agendadas'
    if (-not (Test-SevenScheduleSection -Configuration $Configuration)) {
        Write-Notice 'config.psd1 sem a secao Schedule: nenhuma tarefa e gerenciada. Rode o Setup.bat para incluir o padrao (12:00 e 19:00) ou adicione a secao.'
        return
    }
    try {
        $tasks = @(Get-SevenScheduleTask -Configuration $Configuration)
    }
    catch {
        Write-Check $false "Schedule invalido: $($_.Exception.Message)"
        return
    }
    foreach ($task in $tasks) { Write-Output "  $(Format-ScheduleTask $task)" }
    if ($tasks.Count -eq 0) { Write-Notice 'Schedule sem tarefas: o backup so roda manualmente.' }
    foreach ($warning in @(Get-SevenScheduleWarning -Tasks $tasks)) { Write-Notice $warning }
    if (-not $IsWindows) {
        Write-Output '  Agendador de Tarefas disponivel somente no Windows.'
        return
    }

    $folderPath = Get-SevenScheduleTaskFolder
    $pwsh = (Get-Process -Id $PID).Path
    $desired = @($tasks | ForEach-Object {
            [pscustomobject]@{
                Task       = $_
                Definition = Get-SevenTaskDefinition -Task $_ -PwshPath $pwsh -ScriptPath $entryScript -WorkingDirectory $root
            }
        })
    $existing = @(Get-ScheduledTask -TaskPath $folderPath -ErrorAction SilentlyContinue)
    $legacy = @(Get-ScheduledTask | Where-Object { $_.TaskPath -ne $folderPath -and (Test-BackupSevenTask $_) })
    $folderState = Get-TaskFolderState

    $plan = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $desired) {
        $current = $existing | Where-Object TaskName -EQ $item.Task.Name | Select-Object -First 1
        if ($null -eq $current) {
            $plan.Add([pscustomobject]@{ Action = 'Create'; Name = $item.Task.Name; Item = $item; Text = "+ criar    $(Format-ScheduleTask $item.Task)" })
            continue
        }
        $hash = Get-SevenTaskDefinitionHash -Description ([string] $current.Description)
        $disabled = [string] $current.State -eq 'Disabled'
        if ($hash -ne $item.Definition.Hash -or $disabled -eq $item.Task.Enabled) {
            $plan.Add([pscustomobject]@{ Action = 'Update'; Name = $item.Task.Name; Item = $item; Text = "~ alterar  $(Format-ScheduleTask $item.Task)" })
        }
    }
    foreach ($task in $existing) {
        if ($task.TaskName -notin @($desired | ForEach-Object { $_.Task.Name })) {
            $plan.Add([pscustomobject]@{ Action = 'Remove'; Name = $task.TaskName; TaskPath = $task.TaskPath; Text = "- remover  $($task.TaskPath)$($task.TaskName) (fora da configuracao)" })
        }
    }
    foreach ($task in $legacy) {
        $plan.Add([pscustomobject]@{ Action = 'Remove'; Name = $task.TaskName; TaskPath = $task.TaskPath; Text = "- remover  $($task.TaskPath)$($task.TaskName) (versao anterior, substituida pela pasta $folderPath)" })
    }

    if ($plan.Count -eq 0 -and $folderState -eq 'ok') {
        Write-Check $true "Tarefas conforme a configuracao ($($desired.Count) em $folderPath, pasta protegida)."
        return
    }

    Write-Output ''
    Write-Output '  Plano:'
    if ($folderState -eq 'missing') { Write-Output "  + criar    pasta $folderPath (acesso: SYSTEM e Administradores)" }
    if ($folderState -eq 'unprotected') { Write-Output "  ~ proteger pasta $folderPath (acesso: SYSTEM e Administradores)" }
    foreach ($step in $plan) { Write-Output "  $($step.Text)" }
    $removals = @($plan | Where-Object Action -EQ 'Remove').Count
    if ($removals -gt 0) {
        Write-Output ''
        Write-Output "  ATENCAO: $removals tarefa(s) serao removidas do Agendador."
    }
    if (-not (Read-YesNo 'Aplicar o plano nas tarefas agendadas?' $true)) {
        Write-Notice 'Tarefas agendadas nao alteradas.'
        return
    }

    try {
        Initialize-TaskFolder -State $folderState
        if ($folderState -ne 'ok') { Write-Check $true "Pasta $folderPath protegida (SYSTEM e Administradores)." }
    }
    catch {
        Write-Check $false "Pasta ${folderPath}: $($_.Exception.Message)"
        return
    }
    foreach ($step in $plan) {
        try {
            if ($step.Action -eq 'Remove') {
                Unregister-ScheduledTask -TaskPath $step.TaskPath -TaskName $step.Name -Confirm:$false
                Write-Check $true "Removida: $($step.TaskPath)$($step.Name)"
            }
            else {
                $null = Register-ScheduledTask -TaskPath $folderPath -TaskName $step.Name -Xml $step.Item.Definition.Xml -Force
                $verb = if ($step.Action -eq 'Create') { 'Criada' } else { 'Atualizada' }
                Write-Check $true "${verb}: $folderPath$($step.Name)"
            }
        }
        catch {
            Write-Check $false "Tarefa $($step.Name): $($_.Exception.Message)"
        }
    }
}

function Invoke-ConfigurationTest([System.Collections.IDictionary] $Configuration) {
    Write-Step 'Testes'
    $tools = $Configuration.Tools
    $database = $Configuration.Database
    $storage = $Configuration.Storage
    try {
        $objects = @(Get-SevenDatabaseObject -MySqlPath $tools.MySql -DefaultsExtraFile $database.DefaultsExtraFile -DatabaseName $database.Name)
        Write-Check $true "MySQL: conectado ao banco $($database.Name) ($($objects.Count) tabelas e views)"
    }
    catch {
        Write-Check $false "MySQL: $($_.Exception.Message)"
    }

    try {
        $null = Test-SevenStorageConfiguration -RclonePath $tools.Rclone -ConfigPath $storage.ConfigPath -RemoteRoot $storage.RemoteRoot
        $listing = @(& $tools.Rclone lsf $storage.RemoteRoot --max-depth 1 --config $storage.ConfigPath 2>&1 | ForEach-Object { "$_" })
        $listingText = $listing -join ' '
        if ($LASTEXITCODE -eq 0) {
            Write-Check $true "S3: $($storage.RemoteRoot) acessivel"
        }
        elseif ($listingText -match 'AccessDenied' -and $listingText -notmatch 'InvalidAccessKeyId|SignatureDoesNotMatch') {
            # Credencial aceita pela AWS; so falta a permissao de listar, que o
            # backup nao usa (envia e confere cada arquivo pelo nome).
            Write-Notice "S3: credencial aceita, mas sem permissao de listar $($storage.RemoteRoot) (s3:ListBucket). O backup nao precisa dela."
        }
        else {
            Write-Check $false "S3: rclone lsf $($storage.RemoteRoot) falhou (codigo $LASTEXITCODE). $(@($listing)[-1])"
        }
    }
    catch {
        Write-Check $false "S3: $($_.Exception.Message)"
    }

    $monitoring = Get-Setting $Configuration 'Monitoring' @{}
    $textfile = [string] (Get-Setting $monitoring 'TextfileDirectory' $defaultTextfile)
    if (-not [bool] (Get-Setting $monitoring 'Enabled' $false)) {
        Write-Output '  Monitoramento desligado.'
    }
    elseif (-not (Test-Path -LiteralPath $textfile -PathType Container)) {
        Write-Notice "Alloy: $textfile ainda nao existe. Rode o alloyctl ([1] Reaplicar, perfil servidor); depois disso o estado e gravado sem novo setup."
    }
    else {
        try {
            $probe = [System.IO.Path]::Combine($textfile, 'setup-test.prom.tmp')
            [System.IO.File]::WriteAllText($probe, "# setup`n", $utf8)
            Remove-Item -LiteralPath $probe -Force
            Write-Check $true "Alloy: gravacao em $textfile"
        }
        catch {
            Write-Check $false "Alloy: sem gravacao em $textfile ($($_.Exception.Message))"
        }
    }
}

# Pastas, ACL de Secrets, testes e tarefas: comum ao setup e ao -Apply.
function Invoke-ConfigurationApply([System.Collections.IDictionary] $Configuration) {
    Write-Step 'Pastas e permissoes'
    $paths = $Configuration.Paths
    foreach ($path in @($paths.RuntimeRoot, $paths.CompletedRoot, $paths.LogRoot)) {
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $path -Force
            Write-Check $true "Criada: $path"
        }
    }
    $secretDirs = @(
        (Split-Path -Parent ([string] $Configuration.Database.DefaultsExtraFile))
        (Split-Path -Parent ([string] $Configuration.Storage.ConfigPath))
    ) | Sort-Object -Unique
    foreach ($dir in $secretDirs) {
        if (Set-PrivateAcl $dir) { Write-Check $true "$dir restrita a SYSTEM e Administradores (ACL ajustada)." }
        elseif ($IsWindows) { Write-Check $true "$dir ja restrita a SYSTEM e Administradores." }
    }

    Invoke-ConfigurationTest -Configuration $Configuration
    Sync-Schedule -Configuration $Configuration
}

if ($IsWindows) {
    $principal = [System.Security.Principal.WindowsPrincipal]::new([System.Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Execute como Administrador (Setup.bat e Aplicar-Configuracao.bat pedem a elevacao).'
    }
}

$modeText = if ($Apply) { 'Aplicando a configuracao' } else { 'Setup' }
Write-Output "$modeText do BackupSeven em $root"
$unblocked = Unblock-PackageFile
if ($unblocked -gt 0) { Write-Output "  $unblocked arquivo(s) desbloqueado(s) (marca de download da internet removida)." }

Import-Module (Join-Path $root 'Modules/Database.psm1') -Force
Import-Module (Join-Path $root 'Modules/Storage.psm1') -Force
Import-Module (Join-Path $root 'Modules/Schedule.psm1') -Force

if ($Apply) {
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "config.psd1 nao encontrado em $root. Rode o Setup.bat primeiro."
    }
    $configuration = Import-PowerShellDataFile -LiteralPath $configPath
    foreach ($secret in @([string] $configuration.Database.DefaultsExtraFile, [string] $configuration.Storage.ConfigPath)) {
        if (Test-Template $secret) { throw "$secret ainda e o modelo do pacote. Rode o Setup.bat primeiro." }
    }
    Invoke-ConfigurationApply -Configuration $configuration
}
else {
    Write-Output 'Enter mantem o valor entre colchetes.'

    $current = @{}
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $current = Import-PowerShellDataFile -LiteralPath $configPath
    }
    $tools = Get-Setting $current 'Tools' @{}
    $database = Get-Setting $current 'Database' @{}
    $fiscal = Get-Setting $current 'Fiscal' @{}
    $storage = Get-Setting $current 'Storage' @{}
    $archive = Get-Setting $current 'Archive' @{}
    $retention = Get-Setting $current 'Retention' @{}
    $monitoring = Get-Setting $current 'Monitoring' @{}

    Write-Step 'Instancia'
    $instanceName = Read-Value 'Nome da instancia (prefixo no S3 e nos nomes dos arquivos)' (Get-Setting $current 'InstanceName' '') '^[A-Za-z0-9][A-Za-z0-9_-]*$'

    Write-Step 'Ferramentas'
    $mysqlDump = Read-ExistingPath 'mysqldump.exe' (Get-Setting $tools 'MySqlDump' '') Leaf
    $mysql = Read-ExistingPath 'mysql.exe' (Get-Setting $tools 'MySql' (Join-Path (Split-Path -Parent $mysqlDump) 'mysql.exe')) Leaf
    $sevenZip = Read-ExistingPath '7z.exe' (Get-Setting $tools 'SevenZip' 'C:\Program Files\7-Zip\7z.exe') Leaf
    $rclone = Read-ExistingPath 'rclone.exe' (Get-Setting $tools 'Rclone' 'C:\Program Files\rclone\rclone.exe') Leaf

    Write-Step 'Banco de dados'
    $databaseName = Read-Value 'Nome do banco' (Get-Setting $database 'Name' '')
    $extraArguments = @(Get-Setting $database 'ExtraArguments' @('--skip-events'))
    $writeMysql = $true
    if (-not (Test-Template $mysqlConfigPath)) {
        $writeMysql = -not (Read-YesNo 'Credencial do MySQL ja preenchida. Manter?' $true)
    }
    if ($writeMysql) {
        $mysqlHost = Read-Value 'Host do MySQL' '127.0.0.1'
        $mysqlPort = Read-Value 'Porta' '3306' '^\d+$'
        $mysqlUser = Read-Value 'Usuario de backup' ''
        $mysqlSecret = Read-Secret 'Senha'
    }

    Write-Step 'Fiscal'
    $fiscalPath = Read-ExistingPath 'Pasta Fiscal' (Get-Setting $fiscal 'SourcePath' 'C:\Seven Sistemas\Fiscal') Container

    Write-Step 'S3 (rclone)'
    $remoteRoot = Read-Value 'Destino remoto (remote:bucket)' (Get-Setting $storage 'RemoteRoot' 's3:') '^[^:]+:.+'
    $remoteName = $remoteRoot.Substring(0, $remoteRoot.IndexOf(':'))
    $writeRclone = $true
    if (-not (Test-Template $rcloneConfigPath)) {
        $writeRclone = -not (Read-YesNo 'Credencial do rclone ja preenchida. Manter?' $true)
    }
    if ($writeRclone) {
        $accessKey = Read-Value 'AWS access key id' ''
        $secretKey = Read-Secret 'AWS secret access key'
        $region = Read-Value 'Regiao' 'sa-east-1' '^[a-z0-9-]+$'
    }

    Write-Step 'Monitoramento (Grafana Alloy)'
    $textfile = [string] (Get-Setting $monitoring 'TextfileDirectory' $defaultTextfile)
    $alloyFound = Test-Path -LiteralPath $textfile -PathType Container
    if (-not $alloyFound) { Write-Output "  Pasta do Alloy ainda nao existe: $textfile (criada pelo alloyctl, [1] Reaplicar)." }
    $monitoringEnabled = Read-YesNo 'Gravar o estado dos backups para o Alloy?' ([bool] (Get-Setting $monitoring 'Enabled' $alloyFound))
    $backupIds = Get-Setting $monitoring 'BackupIds' $null
    # Ate a 0.4.x o setup gravava ExpectedIntervalHours fixo; com Schedule o
    # intervalo e calculado. Valor explicito so e mantido em configs com Schedule.
    $intervals = if (Test-SevenScheduleSection -Configuration $current) { Get-Setting $monitoring 'ExpectedIntervalHours' $null } else { $null }

    Write-Step 'Agendamentos'
    if (Test-SevenScheduleSection -Configuration $current) {
        $scheduleText = ConvertTo-Psd1Value $current.Schedule 4
        Write-Output '  Mantidos os agendamentos de config.psd1 (secao Schedule).'
    }
    else {
        $scheduleText = "@{`n        Tasks = @(`n            '12:00'`n            '19:00'`n        )`n    }"
        Write-Output '  Padrao: Full diario as 12:00 e 19:00. Para mudar, edite a secao Schedule e rode Aplicar-Configuracao.bat.'
    }

    Write-Step 'Credenciais'
    $null = New-Item -ItemType Directory -Path $secretsPath -Force
    if ($writeMysql) {
        $mysqlText = "[client]`nhost=$mysqlHost`nport=$mysqlPort`nuser=$(ConvertTo-OptionValue $mysqlUser)`npassword=$(ConvertTo-OptionValue $mysqlSecret)`n"
        [System.IO.File]::WriteAllText($mysqlConfigPath, $mysqlText, $utf8)
        Write-Check $true "Gravado: $mysqlConfigPath"
    }
    else {
        Write-Check $true "Mantido: $mysqlConfigPath"
    }

    if ($writeRclone) {
        $rcloneText = @"
[$remoteName]
type = s3
provider = AWS
access_key_id = $accessKey
secret_access_key = $secretKey
region = $region
location_constraint = $region
no_check_bucket = true

"@
        [System.IO.File]::WriteAllText($rcloneConfigPath, $rcloneText.Replace("`r`n", "`n"), $utf8)
        Write-Check $true "Gravado: $rcloneConfigPath"
    }
    else {
        Write-Check $true "Mantido: $rcloneConfigPath"
    }

    $extraText = ($extraArguments | ForEach-Object { "            $(ConvertTo-Psd1 ([string] $_))" }) -join "`n"
    $monitoringExtra = ''
    if ($backupIds -is [System.Collections.IDictionary]) {
        $monitoringExtra += "`n        BackupIds         = $(ConvertTo-Psd1Value $backupIds 8)"
    }
    if ($intervals -is [System.Collections.IDictionary]) {
        $monitoringExtra += "`n        ExpectedIntervalHours = $(ConvertTo-Psd1Value $intervals 8)"
    }
    $configText = @"
@{
    # Gerado pelo Setup-BackupSeven.ps1. Pode ser editado manualmente; depois
    # de alterar Schedule, rode Aplicar-Configuracao.bat.
    InstanceName = $(ConvertTo-Psd1 $instanceName)

    Tools = @{
        MySqlDump = $(ConvertTo-Psd1 $mysqlDump)
        MySql     = $(ConvertTo-Psd1 $mysql)
        SevenZip  = $(ConvertTo-Psd1 $sevenZip)
        Rclone    = $(ConvertTo-Psd1 $rclone)
    }

    Database = @{
        Name              = $(ConvertTo-Psd1 $databaseName)
        DefaultsExtraFile = $(ConvertTo-Psd1 $mysqlConfigPath)
        ExtraArguments    = @(
$extraText
        )
    }

    Fiscal = @{
        SourcePath = $(ConvertTo-Psd1 $fiscalPath)
    }

    Storage = @{
        ConfigPath = $(ConvertTo-Psd1 $rcloneConfigPath)
        RemoteRoot = $(ConvertTo-Psd1 $remoteRoot)
    }

    Archive = @{
        CompressionLevel = $([int] (Get-Setting $archive 'CompressionLevel' 5))
        CpuLimitPercent  = $([int] (Get-Setting $archive 'CpuLimitPercent' 50))
    }

    Paths = @{
        RuntimeRoot   = $(ConvertTo-Psd1 (Join-Path $root 'Runtime'))
        CompletedRoot = $(ConvertTo-Psd1 (Join-Path $root 'Completed'))
        LogRoot       = $(ConvertTo-Psd1 (Join-Path $root 'Logs'))
    }

    Retention = @{
        CompletedDays = $([int] (Get-Setting $retention 'CompletedDays' 7))
        LogDays       = $([int] (Get-Setting $retention 'LogDays' 30))
    }

    Monitoring = @{
        Enabled           = `$$($monitoringEnabled.ToString().ToLowerInvariant())
        TextfileDirectory = $(ConvertTo-Psd1 $textfile)
        Service           = $(ConvertTo-Psd1 ([string] (Get-Setting $monitoring 'Service' 'seven')))$monitoringExtra
    }

    # Tarefas agendadas (pasta protegida \BackupSeven\). Cada item e um horario
    # ('19:00' = Full, diario) ou @{ At; Mode; Frequency; Days; DaysOfMonth;
    # Name; Enabled }. Veja o RUNBOOK. Aplicar: Aplicar-Configuracao.bat.
    Schedule = $scheduleText
}
"@
    $configText = $configText.Replace("`r`n", "`n") + "`n"

    # Regrava somente se algum valor mudou (formatacao e ordem nao contam).
    $candidatePath = Join-Path ([System.IO.Path]::GetTempPath()) ("BackupSeven-config-$([guid]::NewGuid().ToString('N')).psd1")
    try {
        [System.IO.File]::WriteAllText($candidatePath, $configText, $utf8)
        $candidate = Import-PowerShellDataFile -LiteralPath $candidatePath
    }
    finally {
        Remove-Item -LiteralPath $candidatePath -Force -ErrorAction SilentlyContinue
    }
    if ($current.Count -gt 0 -and (ConvertTo-CanonicalJson $current) -ceq (ConvertTo-CanonicalJson $candidate)) {
        Write-Check $true "Mantido: $configPath (sem alteracoes)"
    }
    else {
        if (Test-Path -LiteralPath $configPath -PathType Leaf) {
            $saved = "$configPath.bak-$([DateTime]::Now.ToString('yyyyMMdd-HHmmss'))"
            Copy-Item -LiteralPath $configPath -Destination $saved
            Write-Output "  Configuracao anterior salva em $saved"
        }
        [System.IO.File]::WriteAllText($configPath, $configText, $utf8)
        Write-Check $true "Gravado: $configPath"
    }

    Invoke-ConfigurationApply -Configuration $candidate

    if (Read-YesNo 'Executar agora um backup Full de teste?' $false) {
        & (Get-Process -Id $PID).Path -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $entryScript -Mode Full -ConfigPath $configPath
        $exitCode = $LASTEXITCODE
        Write-Check ($exitCode -eq 0) "Backup de teste: exit code $exitCode (0 = sucesso; detalhes em $(Join-Path $root 'Logs'))"
    }
}

Write-Output ''
if ($failures.Count -gt 0) {
    Write-Output "Concluido com $($failures.Count) erro(s) e $($notices.Count) aviso(s). Corrija os erros e execute de novo."
    exit 1
}
if ($notices.Count -gt 0) {
    Write-Output "Concluido sem erros, com $($notices.Count) aviso(s)."
}
else {
    Write-Output 'Concluido sem erros.'
}
