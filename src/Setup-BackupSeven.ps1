#requires -Version 7.0

<#
.SYNOPSIS
Configura ou revisa o BackupSeven na pasta onde o pacote foi extraido.

.DESCRIPTION
Pergunta os dados da instalacao (os valores atuais aparecem como padrao; Enter
mantem) e altera somente o que estiver diferente: config.psd1 (com copia da
versao anterior), Secrets\mysql-backup.cnf e Secrets\rclone.conf (credenciais
preenchidas podem ser mantidas), a ACL de Secrets e as tarefas agendadas que
executam o Backup-Seven.ps1. Tambem remove a marca de arquivo baixado da
internet dos arquivos da pasta e testa MySQL, rclone/S3 e a pasta do Grafana
Alloy. Pode ser executado de novo a qualquer momento.

Execute em um PowerShell 7 como Administrador, dentro da pasta extraida:
pwsh -ExecutionPolicy Bypass -File .\Setup-BackupSeven.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$configPath = Join-Path $root 'config.psd1'
$secretsPath = Join-Path $root 'Secrets'
$mysqlConfigPath = Join-Path $secretsPath 'mysql-backup.cnf'
$rcloneConfigPath = Join-Path $secretsPath 'rclone.conf'
$entryScript = Join-Path $root 'Backup-Seven.ps1'
$defaultTextfile = 'C:\ProgramData\GrafanaLabs\Alloy\textfile\backup'
$defaultTaskPath = '\ASSESSORIA SCRIPTS\'
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

function Get-TaskArgument([string] $Mode) {
    return "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$entryScript`" -Mode $Mode"
}

# Tarefas existentes que executam o Backup-Seven.ps1 (qualquer nome ou pasta):
# so a acao e corrigida; gatilhos, conta e configuracoes sao mantidos.
function Sync-BackupTask {
    $pwsh = (Get-Process -Id $PID).Path
    $tasks = @(Get-ScheduledTask | Where-Object {
            @($_.Actions | Where-Object { $_.PSObject.Properties['Arguments'] -and $_.Arguments -match 'Backup-Seven\.ps1' }).Count -gt 0
        })

    if ($tasks.Count -eq 0) {
        if (-not (Read-YesNo 'Nenhuma tarefa do BackupSeven encontrada. Criar as tarefas Full das 12:00 e 19:00 (SYSTEM)?' $true)) {
            Write-Notice 'Nenhuma tarefa agendada; o backup so roda manualmente.'
            return
        }
        $action = New-ScheduledTaskAction -Execute $pwsh -Argument (Get-TaskArgument 'Full') -WorkingDirectory $root
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew
        $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        foreach ($time in @('12:00', '19:00')) {
            $name = "BackupSeven - Full - $($time.Replace(':', 'h'))"
            $null = Register-ScheduledTask -TaskPath $defaultTaskPath -TaskName $name -Action $action `
                -Trigger (New-ScheduledTaskTrigger -Daily -At $time) -Settings $settings -Principal $taskPrincipal `
                -Description "Backup completo do Seven - Database + Fiscal - $time"
            Write-Check $true "Tarefa criada: $defaultTaskPath$name"
        }
        return
    }

    foreach ($task in $tasks) {
        $label = "$($task.TaskPath)$($task.TaskName)"
        $changed = $false
        $actions = foreach ($action in $task.Actions) {
            if (-not ($action.PSObject.Properties['Arguments'] -and $action.Arguments -match 'Backup-Seven\.ps1')) {
                $action
                continue
            }
            $mode = if ($action.Arguments -match '-Mode\s+(\w+)') { $Matches[1] } else { 'Full' }
            $execute = if ($action.Execute -match 'pwsh(\.exe)?"?$') { $action.Execute } else { $pwsh }
            $arguments = Get-TaskArgument $mode
            if ($action.Arguments -ceq $arguments -and $action.Execute -eq $execute -and $action.WorkingDirectory -eq $root) {
                $action
                continue
            }
            $changed = $true
            Write-Output "  $label"
            Write-Output "    atual: $($action.Execute) $($action.Arguments)"
            Write-Output "    novo:  $execute $arguments"
            New-ScheduledTaskAction -Execute $execute -Argument $arguments -WorkingDirectory $root
        }

        if (-not $changed) {
            Write-Check $true "Tarefa $label ja atualizada"
            continue
        }
        if (-not (Read-YesNo "  Atualizar a acao da tarefa (gatilhos e conta mantidos)?" $true)) {
            Write-Notice "Tarefa $label mantida sem -ExecutionPolicy Bypass; pode ser recusada pela politica de execucao."
            continue
        }
        try {
            $null = Set-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName -Action @($actions)
            Write-Check $true "Tarefa $label atualizada"
        }
        catch {
            Write-Check $false "Tarefa $label nao atualizada ($($_.Exception.Message)); ajuste a acao no Agendador de Tarefas."
        }
    }
}

if ($IsWindows) {
    $principal = [System.Security.Principal.WindowsPrincipal]::new([System.Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Execute este setup em um PowerShell 7 como Administrador.'
    }
}

Write-Output "Setup do BackupSeven em $root"
Write-Output 'Enter mantem o valor entre colchetes.'

$unblocked = Unblock-PackageFile
if ($unblocked -gt 0) { Write-Output "  $unblocked arquivo(s) desbloqueado(s) (marca de download da internet removida)." }

Import-Module (Join-Path $root 'Modules/Database.psm1') -Force
Import-Module (Join-Path $root 'Modules/Storage.psm1') -Force

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
$intervals = Get-Setting $monitoring 'ExpectedIntervalHours' @{ Database = 17; Fiscal = 17 }
$backupIds = Get-Setting $monitoring 'BackupIds' $null

Write-Step 'Arquivos e permissoes'
foreach ($path in @($secretsPath, (Join-Path $root 'Runtime'), (Join-Path $root 'Completed'), (Join-Path $root 'Logs'))) {
    $null = New-Item -ItemType Directory -Path $path -Force
}
if (Set-PrivateAcl $secretsPath) {
    Write-Check $true 'Secrets restrita a SYSTEM e Administradores (ACL ajustada).'
}
elseif ($IsWindows) {
    Write-Check $true 'Secrets ja restrita a SYSTEM e Administradores.'
}

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
$backupIdsText = ''
if ($backupIds -is [System.Collections.IDictionary]) {
    $backupIdsText = "`n        BackupIds = @{`n" + (($backupIds.Keys | Sort-Object | ForEach-Object {
                "            $_ = $(ConvertTo-Psd1 ([string] $backupIds[$_]))" }) -join "`n") + "`n        }"
}
$configText = @"
@{
    # Gerado pelo Setup-BackupSeven.ps1. Pode ser editado manualmente.
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
        Service           = $(ConvertTo-Psd1 ([string] (Get-Setting $monitoring 'Service' 'seven')))$backupIdsText
        ExpectedIntervalHours = @{
            Database = $([double] (Get-Setting $intervals 'Database' 17))
            Fiscal   = $([double] (Get-Setting $intervals 'Fiscal' 17))
        }
    }
}
"@
$configText = $configText.Replace("`r`n", "`n")

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

Write-Step 'Testes'
try {
    $objects = @(Get-SevenDatabaseObject -MySqlPath $mysql -DefaultsExtraFile $mysqlConfigPath -DatabaseName $databaseName)
    Write-Check $true "MySQL: conectado ao banco $databaseName ($($objects.Count) tabelas e views)"
}
catch {
    Write-Check $false "MySQL: $($_.Exception.Message)"
}

try {
    $null = Test-SevenStorageConfiguration -RclonePath $rclone -ConfigPath $rcloneConfigPath -RemoteRoot $remoteRoot
    $listing = @(& $rclone lsf $remoteRoot --max-depth 1 --config $rcloneConfigPath 2>&1 | ForEach-Object { "$_" })
    $listingText = $listing -join ' '
    if ($LASTEXITCODE -eq 0) {
        Write-Check $true "S3: $remoteRoot acessivel"
    }
    elseif ($listingText -match 'AccessDenied' -and $listingText -notmatch 'InvalidAccessKeyId|SignatureDoesNotMatch') {
        # Credencial aceita pela AWS; so falta a permissao de listar, que o
        # backup nao usa (envia e confere cada arquivo pelo nome).
        Write-Notice "S3: credencial aceita, mas sem permissao de listar $remoteRoot (s3:ListBucket). O backup nao precisa dela; confirme com o backup de teste."
    }
    else {
        Write-Check $false "S3: rclone lsf $remoteRoot falhou (codigo $LASTEXITCODE). $(@($listing)[-1])"
    }
}
catch {
    Write-Check $false "S3: $($_.Exception.Message)"
}

if (-not $monitoringEnabled) {
    Write-Output '  Monitoramento desligado.'
}
elseif (-not (Test-Path -LiteralPath $textfile -PathType Container)) {
    Write-Notice "Alloy: $textfile ainda nao existe. Rode o alloyctl ([1] Reaplicar, perfil servidor); depois disso o estado e gravado sem novo setup. Ate la, cada execucao so registra um aviso no log."
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

if ($IsWindows) {
    Write-Step 'Tarefas agendadas'
    Sync-BackupTask
}

if (Read-YesNo 'Executar agora um backup Full de teste?' $false) {
    & (Get-Process -Id $PID).Path -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $entryScript -Mode Full -ConfigPath $configPath
    $exitCode = $LASTEXITCODE
    Write-Check ($exitCode -eq 0) "Backup de teste: exit code $exitCode (0 = sucesso; detalhes em $(Join-Path $root 'Logs'))"
}

Write-Output ''
if ($failures.Count -gt 0) {
    Write-Output "Setup concluido com $($failures.Count) erro(s) e $($notices.Count) aviso(s). Corrija os erros e execute o setup de novo."
    exit 1
}
if ($notices.Count -gt 0) {
    Write-Output "Setup concluido sem erros, com $($notices.Count) aviso(s)."
}
else {
    Write-Output 'Setup concluido sem erros.'
}
