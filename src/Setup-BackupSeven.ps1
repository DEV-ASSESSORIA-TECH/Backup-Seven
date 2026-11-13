#requires -Version 7.0

<#
.SYNOPSIS
Configura o BackupSeven na pasta onde o pacote foi extraido.

.DESCRIPTION
Pergunta os dados da instalacao (os valores atuais aparecem como padrao; Enter
mantem), grava config.psd1, Secrets\mysql-backup.cnf e Secrets\rclone.conf,
cria as pastas, restringe Secrets a SYSTEM e Administradores e testa MySQL,
rclone/S3 e a pasta do Grafana Alloy. No fim, oferece criar as tarefas
agendadas e executar um backup de teste.

Execute em um PowerShell 7 como Administrador, dentro da pasta extraida:
pwsh -File .\Setup-BackupSeven.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
Import-Module (Join-Path $root 'Modules/Database.psm1') -Force
Import-Module (Join-Path $root 'Modules/Storage.psm1') -Force

$configPath = Join-Path $root 'config.psd1'
$secretsPath = Join-Path $root 'Secrets'
$mysqlConfigPath = Join-Path $secretsPath 'mysql-backup.cnf'
$rcloneConfigPath = Join-Path $secretsPath 'rclone.conf'
$defaultTextfile = 'C:\ProgramData\GrafanaLabs\Alloy\textfile\backup'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$failures = [System.Collections.Generic.List[string]]::new()

function Write-Step([string] $Text) { Write-Output ''; Write-Output "== $Text" }
function Write-Check([bool] $Ok, [string] $Text) {
    if ($Ok) { Write-Output "  [ OK ] $Text" } else { Write-Output "  [ERRO] $Text"; $failures.Add($Text) }
}

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

# SYSTEM e Administradores com controle total, sem heranca.
function Set-PrivateAcl([string] $Path) {
    if (-not $IsWindows) { return }
    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $identity = [System.Security.Principal.SecurityIdentifier]::new($sid)
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                $identity, 'FullControl', $inherit, 'None', 'Allow'))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

if ($IsWindows) {
    $principal = [System.Security.Principal.WindowsPrincipal]::new([System.Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Execute este setup em um PowerShell 7 como Administrador.'
    }
}

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

Write-Output "Setup do BackupSeven em $root"
Write-Output 'Enter mantem o valor entre colchetes.'

Write-Step 'Instancia'
$instanceName = Read-Value 'Nome da instancia (cliente/local, usado nos nomes e no S3)' (Get-Setting $current 'InstanceName' '') '^[A-Za-z0-9][A-Za-z0-9_-]*$'

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
if (-not $alloyFound) { Write-Output "  Pasta do Alloy nao encontrada: $textfile (instale o Alloy no perfil servidor para criar)." }
$monitoringEnabled = Read-YesNo 'Gravar o estado dos backups para o Alloy?' ([bool] (Get-Setting $monitoring 'Enabled' $alloyFound))
$intervals = Get-Setting $monitoring 'ExpectedIntervalHours' @{ Database = 17; Fiscal = 17 }

Write-Step 'Gravando arquivos'
foreach ($path in @($secretsPath, (Join-Path $root 'Runtime'), (Join-Path $root 'Completed'), (Join-Path $root 'Logs'))) {
    $null = New-Item -ItemType Directory -Path $path -Force
}
Set-PrivateAcl $secretsPath
Write-Output '  Secrets restrita a SYSTEM e Administradores.'

if ($writeMysql) {
    $mysqlText = "[client]`nhost=$mysqlHost`nport=$mysqlPort`nuser=$(ConvertTo-OptionValue $mysqlUser)`npassword=$(ConvertTo-OptionValue $mysqlSecret)`n"
    [System.IO.File]::WriteAllText($mysqlConfigPath, $mysqlText, $utf8)
    Write-Output "  $mysqlConfigPath"
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
    Write-Output "  $rcloneConfigPath"
}

if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    $saved = "$configPath.bak-$([DateTime]::Now.ToString('yyyyMMdd-HHmmss'))"
    Copy-Item -LiteralPath $configPath -Destination $saved
    Write-Output "  Configuracao anterior salva em $saved"
}

$extraText = ($extraArguments | ForEach-Object { "            $(ConvertTo-Psd1 ([string] $_))" }) -join "`n"
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
        Service           = $(ConvertTo-Psd1 ([string] (Get-Setting $monitoring 'Service' 'seven')))
        ExpectedIntervalHours = @{
            Database = $([double] (Get-Setting $intervals 'Database' 17))
            Fiscal   = $([double] (Get-Setting $intervals 'Fiscal' 17))
        }
    }
}
"@
[System.IO.File]::WriteAllText($configPath, $configText.Replace("`r`n", "`n"), $utf8)
$null = Import-PowerShellDataFile -LiteralPath $configPath
Write-Output "  $configPath"

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
    $listing = & $rclone lsf $remoteRoot --max-depth 1 --config $rcloneConfigPath 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Check $true "S3: $remoteRoot acessivel"
    }
    else {
        Write-Check $false "S3: rclone lsf $remoteRoot falhou (codigo $LASTEXITCODE). $(@($listing)[-1])"
    }
}
catch {
    Write-Check $false "S3: $($_.Exception.Message)"
}

if ($monitoringEnabled) {
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

if ($IsWindows -and (Read-YesNo 'Criar ou atualizar as tarefas agendadas Full (12:00 e 19:00, como SYSTEM)?' $true)) {
    $pwsh = (Get-Process -Id $PID).Path
    $action = New-ScheduledTaskAction -Execute $pwsh -WorkingDirectory $root `
        -Argument "-NoLogo -NoProfile -NonInteractive -File `"$(Join-Path $root 'Backup-Seven.ps1')`" -Mode Full"
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    foreach ($time in @('12:00', '19:00')) {
        $name = "BackupSeven - Full - $($time.Replace(':', 'h'))"
        $null = Register-ScheduledTask -TaskPath '\ASSESSORIA SCRIPTS\' -TaskName $name -Action $action `
            -Trigger (New-ScheduledTaskTrigger -Daily -At $time) -Settings $settings -Principal $taskPrincipal `
            -Description "Backup completo do Seven - Database + Fiscal - $time" -Force
        Write-Output "  \ASSESSORIA SCRIPTS\$name"
    }
}

if (Read-YesNo 'Executar agora um backup Full de teste?' $false) {
    & (Get-Process -Id $PID).Path -NoLogo -NoProfile -NonInteractive -File (Join-Path $root 'Backup-Seven.ps1') -Mode Full -ConfigPath $configPath
    $exitCode = $LASTEXITCODE
    Write-Check ($exitCode -eq 0) "Backup de teste: exit code $exitCode (0 = sucesso; detalhes em $(Join-Path $root 'Logs'))"
}

Write-Output ''
if ($failures.Count -eq 0) {
    Write-Output 'Setup concluido sem erros.'
}
else {
    Write-Output "Setup concluido com $($failures.Count) erro(s). Corrija e execute o setup de novo."
    exit 1
}
