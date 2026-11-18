Set-StrictMode -Version Latest
foreach ($name in @('Configuration','Runtime','Artifacts','Schedule','Capacity','Encryption','Storage','Process')) { Import-Module (Join-Path $PSScriptRoot "$name.psm1") }
Import-Module (Join-Path $PSScriptRoot '../Providers/SQLAnywhere/SQLAnywhere.psm1')

function ConvertTo-DBDataLiteral {
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return '$null' }
    if ($Value -is [bool]) { if ($Value) { return '$true' } else { return '$false' } }
    if ($Value -is [Collections.IDictionary]) {
        $pairs = @($Value.Keys | Sort-Object | ForEach-Object { "$(ConvertTo-DBDataLiteral ([string] $_)) = $(ConvertTo-DBDataLiteral $Value[$_])" })
        return "@{`n" + ($pairs -join ";`n") + "`n}"
    }
    if ($Value -is [string]) { return "'" + $Value.Replace("'", "''") + "'" }
    if ($Value -is [Collections.IEnumerable]) {
        return '@(' + ((@($Value) | ForEach-Object { ConvertTo-DBDataLiteral $_ }) -join ', ') + ')'
    }
    if ($Value -is [ValueType]) { return [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture) }
    throw 'Unsupported configuration value type.'
}

function Set-DBPrivateFile {
    param([string] $Path)
    if (-not $IsWindows) { return }
    $acl = [Security.AccessControl.FileSecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'Allow'))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function Test-DBPrivateAcl {
    param([string] $Path)
    if (-not $IsWindows) { throw 'DBBackup setup requires Windows NTFS ACLs.' }
    if (-not (Test-DBPrivateAccess $Path)) { throw "Private path grants access beyond SYSTEM and Administrators: $Path. Run Aplicar-Configuracao.bat (Setup.ps1 -Apply)." }
}

function Test-DBInstance {
    param([Collections.IDictionary] $Configuration, [string] $InstancesRoot)
    Assert-DBInstanceIsolation $Configuration $InstancesRoot
    $null = Get-DBScheduleTask $Configuration
    $credential = if ($Configuration.Provider -eq 'MySQL') { $Configuration.Database.DefaultsExtraFile } else { $Configuration.Database.ConnectionOptionsFile }
    foreach ($file in @($Configuration.ConfigPath, $credential, $Configuration.Storage.ConfigPath, $Configuration.Encryption.RecipientsFile)) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Required instance file is missing: $file" }
        if ((Get-Content -LiteralPath $file -Raw) -match 'REPLACE_') { throw "An instance file still contains placeholders: $file" }
        Test-DBPrivateAcl $file
    }
    # Existing state directories must already be private; a run never rewrites
    # the permissions of a directory it did not create.
    foreach ($path in $Configuration.Paths.Values) { if (Test-Path -LiteralPath $path) { Test-DBPrivateAcl $path } }
    if ($Configuration.Provider -eq 'SQLAnywhere') {
        $connection = Read-DBSqlConnection $Configuration.Database.ConnectionOptionsFile
        if ($connection.DBN -cne $Configuration.Database.Name) { throw 'SQL DBN must match Database.Name.' }
    }
    $null = Assert-DBBackupDependency -Configuration $Configuration -Jobs $Configuration.Jobs
    foreach ($path in $Configuration.Paths.Values) { Assert-DBFreeSpace -Path $path -RequiredBytes 0 -ReserveBytes $Configuration.Execution.ReserveBytes }
    [pscustomobject]@{Instance=$Configuration.InstanceName;Provider=$Configuration.Provider;Jobs=@($Configuration.Jobs.Id);Status='LOCAL_CHECKS_OK';RemoteDatabaseChecked=$false}
}

function Initialize-DBInstance {
    param([string] $ConfigPath, [ValidateSet('MySQL','SQLAnywhere')][string] $Provider,
        [string] $InstanceName, [string] $TemplateRoot, [string] $InstancesRoot)
    Assert-DBIdentifier $InstanceName
    $full = Resolve-DBPath $ConfigPath (Get-Location).Path
    if (-not (Test-DBPathWithin $full ([IO.Path]::GetFullPath($InstancesRoot)))) { throw 'ConfigPath must be under InstancesRoot.' }
    if (Test-Path -LiteralPath $full) { throw 'Instance configuration already exists; refusing overwrite.' }
    $data = Import-PowerShellDataFile -LiteralPath (Join-Path $TemplateRoot "$Provider/config.example.psd1")
    $data.InstanceName = $InstanceName
    $root = Split-Path -Parent $full
    $candidateData = Import-PowerShellDataFile -LiteralPath (Join-Path $TemplateRoot "$Provider/config.example.psd1")
    $candidateData.InstanceName = $InstanceName
    Assert-DBInstanceIsolation (Read-DBConfiguration -Path $full -Data $candidateData) $InstancesRoot
    Set-DBPrivateDirectory $root -Force
    Set-DBPrivateDirectory (Join-Path $root 'Secrets') -Force
    # Validate the candidate and isolation BEFORE committing its config file.
    $candidate = Join-Path $root "config-$([guid]::NewGuid().ToString('N')).tmp.psd1"
    try {
        Set-Content -LiteralPath $candidate -Value (ConvertTo-DBDataLiteral $data) -Encoding utf8
        $c = Read-DBConfiguration $candidate
        Assert-DBInstanceIsolation $c $InstancesRoot
        Move-Item -LiteralPath $candidate -Destination $full -ErrorAction Stop
        Set-DBPrivateFile $full
    }
    finally { if (Test-Path -LiteralPath $candidate) { Remove-Item -LiteralPath $candidate -Force } }
    return $full
}

function Write-DBSetupMessage {
    <# Operator-facing line on the console (not part of the pipeline output). #>
    param([string] $Message)
    $Message | Out-Host
}

function Read-DBValue {
    param([string] $Prompt, [string] $Default)
    $answer = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    if ($answer -match '[\r\n]') { throw 'Newlines are not accepted.' }
    return $answer.Trim()
}

function Read-DBRequiredValue {
    <# Asks until Validate accepts a non-empty answer (3 attempts); Validate throws a user-facing reason. #>
    param([string] $Prompt, [string] $Default, [scriptblock] $Validate = { })
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $value = Read-DBValue $Prompt $Default
        try {
            if ([string]::IsNullOrWhiteSpace($value)) { throw 'Valor obrigatorio.' }
            $null = & $Validate $value
            return $value
        }
        catch {
            if ($attempt -ge 3) { throw "$Prompt`: $($_.Exception.Message)" }
            Write-Warning "$($_.Exception.Message) Tente novamente."
        }
    }
}

function Read-DBConfirmation {
    param([string] $Prompt, [bool] $Default = $true)
    $suffix = if ($Default) { 'S/n' } else { 's/N' }
    $answer = Read-Host "$Prompt [$suffix]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim() -match '^(?i:s|sim|y|yes)$'
}

function Read-DBSecret {
    param([string] $Prompt)
    $secure = Read-Host $Prompt -AsSecureString
    try { return [Net.NetworkCredential]::new('', $secure).Password }
    finally { $secure.Dispose() }
}

function Find-DBToolCandidate {
    <# A likely installed path for a tool, used only as the suggested default. #>
    param([string] $Key)
    $programFiles = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
    $patterns = switch ($Key) {
        'MySql' { $programFiles | ForEach-Object { Join-Path $_ 'MySQL\MySQL Server *\bin\mysql.exe' } }
        'MySqlDump' { $programFiles | ForEach-Object { Join-Path $_ 'MySQL\MySQL Server *\bin\mysqldump.exe' } }
        'DbBackup' { $programFiles | ForEach-Object { Join-Path $_ 'SQL Anywhere *\Bin64\dbbackup.exe' } }
        default { @() }
    }
    foreach ($pattern in $patterns) {
        $found = @(Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)
        if ($found.Count -gt 0) { return $found[0].FullName }
    }
    $command = switch ($Key) { 'SevenZip' { '7z.exe' } 'Age' { 'age.exe' } 'Rclone' { 'rclone.exe' } default { $null } }
    if ($command) {
        $resolved = Get-Command $command -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $resolved) { return $resolved.Source }
    }
    return $null
}

function Split-DBRemoteRoot {
    <# remote:bucket/prefix -> Remote, Bucket, Prefix (placeholders become empty). #>
    param([string] $RemoteRoot)
    $result = [pscustomobject]@{ Remote = 's3'; Bucket = ''; Prefix = '' }
    if ($RemoteRoot -match '^(?<remote>[A-Za-z0-9_-]+):(?<path>.*)$') {
        $result.Remote = $Matches.remote
        $parts = $Matches.path.Trim('/').Split('/', 2)
        if ($parts[0] -and $parts[0] -notmatch 'REPLACE_') { $result.Bucket = $parts[0] }
        if ($parts.Count -gt 1) { $result.Prefix = $parts[1] }
    }
    return $result
}

function Set-DBInteractiveConfiguration {
    <#
    Asks only what the instance needs, validating each answer immediately:
    executables (must exist), database name, S3 bucket and prefix (the
    complete destination; the instance name is not added) and the daily time.
    #>
    param([string] $ConfigPath)
    $data = Import-PowerShellDataFile -LiteralPath $ConfigPath
    $labels = [ordered]@{
        MySql = 'Executavel mysql.exe'; MySqlDump = 'Executavel mysqldump.exe'; DbBackup = 'Executavel dbbackup.exe (SQL Anywhere)'
        SevenZip = 'Executavel 7z.exe'; Age = 'Executavel age.exe'; Rclone = 'Executavel rclone.exe'
    }
    foreach ($name in @($labels.Keys | Where-Object { $data.Tools.Contains($_) })) {
        $default = [string] $data.Tools[$name]
        if (-not (Test-Path -LiteralPath $default -PathType Leaf)) {
            $candidate = Find-DBToolCandidate $name
            if ($candidate) { $default = $candidate }
        }
        $data.Tools[$name] = Read-DBRequiredValue $labels[$name] $default {
            param($value)
            if (-not (Test-Path -LiteralPath $value -PathType Leaf)) { throw "Arquivo nao encontrado: $value" }
        }
    }

    $databaseDefault = if ([string] $data.Database.Name -match 'REPLACE_') { '' } else { [string] $data.Database.Name }
    $databasePrompt = if ($data.Provider -eq 'MySQL') { 'Nome do banco MySQL' } else { 'Nome do banco SQL Anywhere (DBN)' }
    $data.Database.Name = Read-DBRequiredValue $databasePrompt $databaseDefault {
        param($value)
        if ($value -match '[\x00-\x1f"''\\/]' -or $value.Length -gt 128) { throw 'Nome de banco invalido.' }
    }

    $current = Split-DBRemoteRoot ([string] $data.Storage.RemoteRoot)
    $bucket = Read-DBRequiredValue 'Bucket S3' $current.Bucket {
        param($value)
        if ($value -cnotmatch '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$') { throw 'Nome de bucket invalido (minusculas, numeros, ponto e hifen; 3 a 63 caracteres).' }
    }
    $prefixDefault = if ($current.Prefix) { $current.Prefix } else { [string] $data.InstanceName }
    Write-DBSetupMessage 'O prefixo e a pasta dentro do bucket onde ficam os backups desta instancia (o nome da instancia nao e acrescentado).'
    $prefix = $null
    for ($attempt = 1; $null -eq $prefix; $attempt++) {
        # Enter keeps the suggestion; '/' selects the bucket root.
        $answer = (Read-DBValue 'Prefixo dentro do bucket (digite / para usar a raiz do bucket)' $prefixDefault).Trim('/')
        try {
            $root = if ($answer) { "$($current.Remote):$bucket/$answer" } else { "$($current.Remote):$bucket" }
            $data.Storage.RemoteRoot = ConvertTo-DBRemoteRoot $root
            $prefix = $answer
        }
        catch {
            if ($attempt -ge 3) { throw }
            Write-Warning "$($_.Exception.Message) Tente novamente."
        }
    }
    Write-DBSetupMessage "Destino: $($data.Storage.RemoteRoot)/<trabalho>/aaaa/mm/dd/ (ex.: $($data.Storage.RemoteRoot)/database/...)"

    $tasks = @()
    if ($data.Contains('Schedule') -and $data.Schedule -is [Collections.IDictionary] -and $data.Schedule.Contains('Tasks')) { $tasks = @($data.Schedule.Tasks) }
    $daily = @($tasks | Where-Object { $_ -is [Collections.IDictionary] -and (-not $_.Contains('Frequency') -or $_.Frequency -ceq 'Daily') })
    if ($tasks.Count -eq 1 -and $daily.Count -eq 1) {
        $daily[0].At = Read-DBRequiredValue 'Horario diario do backup (HH:mm)' ([string] $daily[0].At) {
            param($value)
            if ($value -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { throw 'Use o formato HH:mm, por exemplo 19:00.' }
        }
    }
    elseif ($tasks.Count -gt 0) {
        Write-DBSetupMessage 'Agenda personalizada encontrada na secao Schedule do config.psd1; mantida sem alteracoes.'
    }

    $temp = "$ConfigPath.$([guid]::NewGuid().ToString('N')).tmp.psd1"
    try {
        Set-Content -LiteralPath $temp -Value (ConvertTo-DBDataLiteral $data) -Encoding utf8
        $null = Read-DBConfiguration $temp
        [IO.File]::Move($temp, $ConfigPath, $true)
        Set-DBPrivateFile $ConfigPath
    }
    finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}

function Initialize-DBSecret {
    param([Collections.IDictionary] $Configuration)
    Set-DBPrivateDirectory $Configuration.SecretsRoot -Force
    $dbFile = if ($Configuration.Provider -eq 'MySQL') { $Configuration.Database.DefaultsExtraFile } else { $Configuration.Database.ConnectionOptionsFile }
    foreach ($file in @($dbFile, $Configuration.Storage.ConfigPath, $Configuration.Encryption.RecipientsFile)) {
        Set-DBPrivateDirectory (Split-Path -Parent $file) -Force
    }
    if (-not (Test-Path -LiteralPath $dbFile)) {
        $noSpaces = { param($value) if ($value -match '\s') { throw 'Nao use espacos.' } }
        if ($Configuration.Provider -eq 'MySQL') {
            $hostName = Read-DBRequiredValue 'Host do servidor MySQL' 'localhost' $noSpaces
            $port = Read-DBRequiredValue 'Porta MySQL' '3306' {
                param($value)
                if ($value -notmatch '^\d+$' -or [int] $value -notin 1..65535) { throw 'Porta invalida.' }
            }
            $server = $null
        }
        else {
            Write-DBSetupMessage 'SQL Anywhere: informe host:porta para um servidor em rede, ou deixe vazio para um servidor local nesta maquina.'
            $hostName = Read-DBValue 'Servidor em rede (host:porta)' ''
            if ($hostName -match '\s') { throw 'O host nao pode conter espacos.' }
            $server = $null
            if (-not $hostName) { $server = Read-DBRequiredValue 'Nome do servidor local (SERVER/ENG)' '' $noSpaces }
        }
        $user = Read-DBRequiredValue 'Usuario de backup do banco' 'backup' $noSpaces
        $password = Read-DBSecret 'Senha do banco'
        try {
            if ($Configuration.Provider -eq 'MySQL') {
                $escape = { param($v) '"' + $v.Replace('\','\\').Replace('"','\"').Replace("`r",'\r').Replace("`n",'\n') + '"' }
                $content = "[client]`nhost=$(& $escape $hostName)`nport=$port`nuser=$(& $escape $user)`npassword=$(& $escape $password)`n"
            }
            else {
                foreach ($value in @($hostName, $server, $user, $password, $Configuration.Database.Name)) {
                    if ($null -ne $value -and $value -match '["\r\n]') { throw 'SQL values cannot contain double quotes or newlines.' }
                }
                $location = if ($hostName) { "HOST='{0}'" -f $hostName.Replace("'","''") } else { "SERVER='{0}'" -f $server.Replace("'","''") }
                $content = '-c "UID=''{0}'';PWD=''{1}'';{2};DBN=''{3}''"' -f $user.Replace("'","''"), $password.Replace("'","''"), $location, $Configuration.Database.Name.Replace("'","''")
            }
            Set-Content -LiteralPath $dbFile -Value $content -Encoding utf8
            Set-DBPrivateFile $dbFile
        }
        finally { $password = $null; $content = $null }
    }
    if (-not (Test-Path -LiteralPath $Configuration.Storage.ConfigPath)) {
        $remote = $Configuration.Storage.RemoteRoot.Split(':')[0]
        $provider = Read-DBRequiredValue 'Provedor S3 do rclone (AWS, Wasabi, Minio, Cloudflare, Other...)' 'AWS' {
            param($value)
            if ($value -cnotmatch '^[A-Za-z0-9]+$') { throw 'Nome de provedor invalido.' }
        }
        $endpoint = ''
        if ($provider -cne 'AWS') {
            # AWS derives the endpoint from the region; other providers need it.
            $endpoint = Read-DBValue 'Endpoint S3 do provedor (ex.: s3.us-east-1.wasabisys.com)' ''
            if ($endpoint -match '\s') { throw 'The S3 endpoint cannot contain spaces.' }
        }
        $access = Read-DBRequiredValue 'Access key ID' '' {
            param($value)
            if ($value -match '\s') { throw 'A chave nao pode conter espacos.' }
        }
        $secret = Read-DBSecret 'Secret access key'
        $regionDefault = if ($provider -ceq 'AWS') { 'sa-east-1' } else { 'us-east-1' }
        $region = Read-DBRequiredValue 'Regiao do bucket' $regionDefault {
            param($value)
            if ($value -notmatch '^[a-z0-9-]+$') { throw 'Regiao invalida (ex.: sa-east-1).' }
        }
        try {
            if ([string]::IsNullOrWhiteSpace($secret) -or $secret -match '[\r\n]') { throw 'The secret access key is empty or contains newlines.' }
            # no_check_bucket: never try to create the bucket, so a least-privilege
            # IAM policy without s3:CreateBucket works.
            $lines = @("[$remote]", 'type = s3', "provider = $provider", 'env_auth = false', "access_key_id = $access", "secret_access_key = $secret", "region = $region", 'no_check_bucket = true')
            if ($endpoint) { $lines += "endpoint = $endpoint" }
            Set-Content -LiteralPath $Configuration.Storage.ConfigPath -Value (($lines -join "`n") + "`n") -Encoding utf8
            Set-DBPrivateFile $Configuration.Storage.ConfigPath
        }
        finally { $secret = $null }
    }
    if (-not (Test-Path -LiteralPath $Configuration.Encryption.RecipientsFile)) {
        # Validate before writing: an invalid file would otherwise be kept by the
        # next setup run (existing secrets are never replaced).
        $recipients = $null
        for ($attempt = 1; $null -eq $recipients; $attempt++) {
            $answer = Read-DBValue 'Destinatarios age PUBLICOS (age1...), separados por virgula' ''
            try { $recipients = @(Get-DBRecipientList @($answer -split ',')) }
            catch {
                if ($attempt -ge 3) { throw }
                Write-Warning "$($_.Exception.Message) Tente novamente."
            }
        }
        Set-Content -LiteralPath $Configuration.Encryption.RecipientsFile -Value $recipients -Encoding utf8
        Set-DBPrivateFile $Configuration.Encryption.RecipientsFile
    }
    # Existing credentials are never replaced by interactive setup. To change
    # them, edit the private file; applying setup reapplies its ACL safely.
    foreach ($file in @($dbFile,$Configuration.Storage.ConfigPath,$Configuration.Encryption.RecipientsFile)) { Set-DBPrivateFile $file }
}

function Test-DBDatabaseConnection {
    <# Read-only connection probe: MySQL SELECT 1 (lists visible databases on failure) or SQL Anywhere dbping -d. #>
    param([Collections.IDictionary] $Configuration, [double] $TimeoutSeconds = 60)
    if ($Configuration.Provider -eq 'MySQL') {
        $common = @("--defaults-extra-file=$($Configuration.Database.DefaultsExtraFile)", '--batch', '--skip-column-names')
        $probe = Invoke-DBTool -Executable $Configuration.Tools.MySql -Arguments ($common + @("--database=$($Configuration.Database.Name)", '--execute=SELECT 1')) -TimeoutSeconds $TimeoutSeconds
        if ($probe.ExitCode -eq 0) { return [pscustomobject]@{ Ok = $true; Message = "Banco $($Configuration.Database.Name) acessivel." } }
        $detail = Protect-DBMessage ([string] $probe.StdErr).Trim()
        $list = Invoke-DBTool -Executable $Configuration.Tools.MySql -Arguments ($common + @('--execute=SHOW DATABASES')) -TimeoutSeconds $TimeoutSeconds
        if ($list.ExitCode -eq 0) {
            $names = @(([string] $list.StdOut) -split "`r?`n" | Where-Object { $_ -and $_ -notin @('information_schema','performance_schema','mysql','sys') })
            return [pscustomobject]@{ Ok = $false; Message = "Conectou, mas o banco $($Configuration.Database.Name) nao esta acessivel ($detail). Bancos visiveis: $($names -join ', ')" }
        }
        return [pscustomobject]@{ Ok = $false; Message = "Falha ao conectar no MySQL: $detail" }
    }
    $dbping = Join-Path (Split-Path -Parent $Configuration.Tools.DbBackup) 'dbping.exe'
    if (-not (Test-Path -LiteralPath $dbping -PathType Leaf)) { return [pscustomobject]@{ Ok = $true; Message = "dbping.exe nao encontrado ao lado do dbbackup.exe; teste do banco ignorado." } }
    $connection = Read-DBSqlConnection $Configuration.Database.ConnectionOptionsFile
    $connection.ASTART = 'NO'
    $options = Join-Path $Configuration.SecretsRoot "dbping-$([guid]::NewGuid().ToString('N')).options"
    try {
        Write-DBSqlOption $options $connection
        $probe = Invoke-DBTool -Executable $dbping -Arguments @('-d', "@$options") -TimeoutSeconds $TimeoutSeconds
        if ($probe.ExitCode -eq 0) { return [pscustomobject]@{ Ok = $true; Message = "Banco $($Configuration.Database.Name) acessivel." } }
        $detail = ConvertTo-DBSafeToolOutput -Text "$($probe.StdOut) $($probe.StdErr)" -Secret $connection.PWD
        return [pscustomobject]@{ Ok = $false; Message = "Falha ao conectar no SQL Anywhere: $detail" }
    }
    finally { if (Test-Path -LiteralPath $options) { Remove-Item -LiteralPath $options -Force } }
}

function Invoke-DBConnectionCheck {
    <#
    Optional, read-only checks before tasks are applied: database login and
    S3 listing of the destination prefix. Writes nothing to the bucket.
    Returns $false when a check failed and the operator chose to stop.
    #>
    param([Collections.IDictionary] $Configuration)
    if (-not (Read-DBConfirmation 'Testar agora a conexao com o banco e com o S3 (somente leitura)?' $true)) { return $true }
    $results = @()
    try { $results += [pscustomobject]@{ Name = 'Banco'; Result = (Test-DBDatabaseConnection -Configuration $Configuration) } }
    catch { $results += [pscustomobject]@{ Name = 'Banco'; Result = [pscustomobject]@{ Ok = $false; Message = (Protect-DBMessage $_.Exception.Message) } } }
    try { $results += [pscustomobject]@{ Name = 'S3'; Result = (Test-DBStorageAccess -RclonePath $Configuration.Tools.Rclone -ConfigPath $Configuration.Storage.ConfigPath -RemoteRoot $Configuration.Storage.RemoteRoot -TimeoutSeconds 120) } }
    catch { $results += [pscustomobject]@{ Name = 'S3'; Result = [pscustomobject]@{ Ok = $false; Message = (Protect-DBMessage $_.Exception.Message) } } }
    foreach ($entry in $results) {
        $mark = if ($entry.Result.Ok) { 'OK  ' } else { 'FALHA' }
        Write-DBSetupMessage "[$mark] $($entry.Name): $($entry.Result.Message)"
    }
    if (@($results | Where-Object { -not $_.Result.Ok }).Count -eq 0) { return $true }
    return (Read-DBConfirmation 'Algum teste falhou. Continuar mesmo assim e aplicar a configuracao?' $false)
}

function Get-DBOwnedTask {
    <# Tasks in \DBBackup\ that belong to this configuration (owner marker). #>
    param([Collections.IDictionary] $Configuration, [AllowEmptyCollection()][object[]] $Existing)
    $owner = Get-DBTaskOwner $Configuration.ConfigPath
    foreach ($task in $Existing) {
        try { [xml] $xml = $task.Xml } catch { continue }
        if ([string] $xml.Task.RegistrationInfo.Description -match "\[owner:$owner\]") { $task }
    }
}

function Get-DBSetupSummary {
    <# Lines for the operator at the end of setup. RegisteredTasks are the tasks found in the scheduler afterwards. #>
    param([Collections.IDictionary] $Configuration, [AllowEmptyCollection()][string[]] $RegisteredTasks = @(), [string] $PwshPath, [string] $ScriptPath)
    $recipients = @(Read-DBRecipient $Configuration.Encryption.RecipientsFile)
    $lines = @(
        '', '===== Resumo do DBBackup ====='
        "Instancia:        $($Configuration.InstanceName) ($($Configuration.Provider))"
        "Banco:            $($Configuration.Database.Name)"
        "Destino S3:       $($Configuration.Storage.RemoteRoot)/<trabalho>/aaaa/mm/dd/"
        "Destinatarios age: $($recipients.Count)"
        "Configuracao:     $($Configuration.ConfigPath)"
        'Diagnostico local: OK'
    )
    $scheduled = @(Get-DBScheduleTask $Configuration)
    if ($scheduled.Count -eq 0) { $lines += 'Agenda:           sem secao Schedule (nao gerenciada)' }
    foreach ($task in $scheduled) {
        $state = if ($task.RegisteredName -in $RegisteredTasks) { 'registrada' } else { 'NAO registrada' }
        $lines += "Tarefa:           $(Get-DBTaskFolder)$($task.RegisteredName) - $($task.Frequency) $($task.At) ($state)"
    }
    $lines += ''
    $lines += 'Proximo passo: rode um backup manual e confira o arquivo no bucket:'
    $lines += "  & `"$PwshPath`" -NoProfile -File `"$ScriptPath`" -ConfigPath `"$($Configuration.ConfigPath)`" -Job database"
    return $lines
}

function Invoke-DBConfigurationApply {
    param([Collections.IDictionary] $Configuration, [string] $InstancesRoot, [string] $ScriptPath,
        [string] $PwshPath, [switch] $PlanOnly)
    Assert-DBInstanceIsolation $Configuration $InstancesRoot
    if ($PlanOnly) {
        # Read-only: no ACL changes, directory creation, credentials or probes.
        $tasks = @()
        if ($Configuration.Contains('Schedule')) { $tasks = @(Get-DBSchedulerSnapshot (Get-DBTaskFolder)) }
        return @(Get-DBSchedulePlan -Configuration $Configuration -Existing $tasks -PwshPath $PwshPath -ScriptPath $ScriptPath -WorkingDirectory (Split-Path $ScriptPath))
    }
    Set-DBPrivateDirectory $Configuration.InstanceRoot -Force
    Set-DBPrivateDirectory $Configuration.SecretsRoot -Force
    Set-DBPrivateFile $Configuration.ConfigPath
    $dbFile = if ($Configuration.Provider -eq 'MySQL') { $Configuration.Database.DefaultsExtraFile } else { $Configuration.Database.ConnectionOptionsFile }
    foreach ($file in @($dbFile, $Configuration.Storage.ConfigPath, $Configuration.Encryption.RecipientsFile)) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Required instance file is missing: $file" }
        Set-DBPrivateFile $file
    }
    # State directories: created private, or kept when already private/empty;
    # a populated directory with foreign permissions is refused, never rewritten.
    foreach ($path in $Configuration.Paths.Values) { Set-DBPrivateDirectory $path -Enforce }
    $null = Test-DBInstance $Configuration $InstancesRoot
    if (-not $Configuration.Contains('Schedule')) { return }
    $folder = Get-DBTaskFolder
    $existing = @(Get-DBSchedulerSnapshot $folder)
    $plan = @(Get-DBSchedulePlan -Configuration $Configuration -Existing $existing -PwshPath $PwshPath -ScriptPath $ScriptPath -WorkingDirectory (Split-Path $ScriptPath))
    foreach ($warning in @(Get-DBScheduleWarning @(Get-DBScheduleTask $Configuration))) { Write-Warning $warning }
    Write-Output "Pasta de tarefas: $folder"
    if ($plan.Count -eq 0) { Write-Output 'Tarefas sem alteracoes.'; return }
    $plan | Select-Object Action,Name | Format-Table | Out-Host
    if ((Read-Host 'Aplicar este plano de tarefas? Digite SIM') -cne 'SIM') { Write-Output 'Tarefas mantidas.'; return }
    # Re-read under the confirmation boundary to avoid applying a stale plan.
    $fresh = @(Get-DBSchedulerSnapshot $folder)
    $check = @(Get-DBSchedulePlan -Configuration $Configuration -Existing $fresh -PwshPath $PwshPath -ScriptPath $ScriptPath -WorkingDirectory (Split-Path $ScriptPath))
    if (($check | ConvertTo-Json -Depth 10 -Compress) -cne ($plan | ConvertTo-Json -Depth 10 -Compress)) { throw 'Task state changed while awaiting confirmation; rerun setup.' }
    Invoke-DBSchedulePlan -Configuration $Configuration -Plan $plan
}

Export-ModuleMember -Function Initialize-DBInstance, Set-DBInteractiveConfiguration, Initialize-DBSecret, Invoke-DBConfigurationApply, Test-DBInstance, ConvertTo-DBDataLiteral, Invoke-DBConnectionCheck, Test-DBDatabaseConnection, Get-DBOwnedTask, Get-DBSetupSummary, Split-DBRemoteRoot
