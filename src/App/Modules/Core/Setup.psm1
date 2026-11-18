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

function Get-DBOwnedTask {
    <# Tasks in \DBBackup\ that belong to this configuration (owner marker). #>
    param([Collections.IDictionary] $Configuration, [AllowEmptyCollection()][object[]] $Existing)
    $owner = Get-DBTaskOwner $Configuration.ConfigPath
    foreach ($task in $Existing) {
        try { [xml] $xml = $task.Xml } catch { continue }
        if ([string] $xml.Task.RegistrationInfo.Description -match "\[owner:$owner\]") { $task }
    }
}

function Restore-DBInheritedAccess {
    <#
    DBBackup 1.x made the whole instance folder and config.psd1 private, so a
    non-elevated editor could not open them. In 2.0 only Secrets and Runtime are
    private: the instance folder and config.psd1 inherit the installation ACL.
    #>
    param([string] $Path)
    if (-not $IsWindows -or -not (Test-Path -LiteralPath $Path)) { return }
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    if (-not $acl.AreAccessRulesProtected) { return }
    $acl.SetAccessRuleProtection($false, $false)
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function Get-DBSecretFile {
    <# Secret files referenced by a configuration (credentials of every job, rclone.conf, recipients). #>
    param([Collections.IDictionary] $Configuration)
    $files = @($Configuration.Storage.ConfigPath, $Configuration.Encryption.RecipientsFile)
    foreach ($job in $Configuration.Jobs) { if ($job.CredentialFile) { $files += $job.CredentialFile } }
    return @($files | Select-Object -Unique)
}

function Protect-DBInstanceSecret {
    <# Secrets and Runtime private (SYSTEM + Administrators); every referenced secret file private. #>
    param([Collections.IDictionary] $Configuration)
    Set-DBPrivateDirectory $Configuration.SecretsRoot -Force
    foreach ($file in Get-DBSecretFile $Configuration) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Required instance file is missing: $file" }
        Set-DBPrivateFile $file
    }
}

function Test-DBInstance {
    param([Collections.IDictionary] $Configuration, [string] $InstancesRoot)
    Assert-DBInstanceIsolation $Configuration $InstancesRoot
    $null = Get-DBScheduleTask $Configuration
    foreach ($file in @($Configuration.ConfigPath) + @(Get-DBSecretFile $Configuration)) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Required instance file is missing: $file" }
        if ((Get-Content -LiteralPath $file -Raw) -match 'REPLACE_') { throw "An instance file still contains placeholders: $file" }
    }
    foreach ($file in Get-DBSecretFile $Configuration) { Test-DBPrivateAcl $file }
    # Runtime holds plaintext work: it must already be private. Completed and
    # Logs are operator folders and keep the installation permissions.
    if (Test-Path -LiteralPath $Configuration.Paths.RuntimeRoot) { Test-DBPrivateAcl $Configuration.Paths.RuntimeRoot }
    foreach ($job in @($Configuration.Jobs | Where-Object Provider -EQ 'SQLAnywhere')) {
        $connection = Read-DBSqlConnection $job.CredentialFile
        if ($connection.DBN -cne $job.Database) { throw "Job $($job.Id): SQL DBN must match the job Database." }
    }
    $null = Assert-DBBackupDependency -Configuration $Configuration -Jobs $Configuration.Jobs
    foreach ($path in $Configuration.Paths.Values) { Assert-DBFreeSpace -Path $path -RequiredBytes 0 -ReserveBytes $Configuration.Execution.ReserveBytes }
    [pscustomobject]@{Instance=$Configuration.InstanceName;Jobs=@($Configuration.Jobs.Id);Status='LOCAL_CHECKS_OK';RemoteDatabaseChecked=$false}
}

function ConvertTo-DBJobId {
    <# Suggested job ID from a database or folder name (identifier rules, lowercase). #>
    param([string] $Value, [string] $Fallback)
    $id = ($Value.ToLowerInvariant() -replace '[^a-z0-9_-]+', '-').Trim('-', '_')
    if ($id.Length -gt 64) { $id = $id.Substring(0, 64).Trim('-', '_') }
    if (-not $id -or $id -notmatch '^[a-z0-9]' -or $id -ieq 'logs') { $id = $Fallback }
    return $id
}

function Get-DBRcloneRemoteName {
    <# First [section] of an rclone.conf; 's3' when the file is new. #>
    param([string] $Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        foreach ($line in Get-Content -LiteralPath $Path) { if ($line -match '^\s*\[([A-Za-z0-9_-]+)\]\s*$') { return $Matches[1] } }
    }
    return 's3'
}

function Confirm-DBKeepSecret {
    <#
    Existing secret file: ask whether to keep it. A replaced file is renamed to
    <name>.old (still inside the private Secrets folder) before a new one is written.
    Returns $true when the file is kept.
    #>
    param([string] $Path, [string] $Description)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $relative = "Secrets\$(Split-Path -Leaf $Path)"
    if (Read-DBConfirmation "Encontrado $relative ($Description). Manter este arquivo?" $true) { return $true }
    $old = "$Path.old"
    if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force }
    Move-Item -LiteralPath $Path -Destination $old
    Write-DBSetupMessage "Arquivo anterior guardado como $relative.old."
    return $false
}

function Initialize-DBSharedSecret {
    <# rclone.conf (S3 credentials of the instance) and recipients.txt: keep existing or create. #>
    param([string] $SecretsRoot)
    $rclone = Join-Path $SecretsRoot 'rclone.conf'
    if (-not (Confirm-DBKeepSecret $rclone 'credenciais S3 do rclone')) {
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
        $region = Read-DBRequiredValue 'Regiao dos buckets' $regionDefault {
            param($value)
            if ($value -notmatch '^[a-z0-9-]+$') { throw 'Regiao invalida (ex.: sa-east-1).' }
        }
        try {
            if ([string]::IsNullOrWhiteSpace($secret) -or $secret -match '[\r\n]') { throw 'The secret access key is empty or contains newlines.' }
            # no_check_bucket: never try to create the bucket, so a least-privilege
            # IAM policy without s3:CreateBucket works.
            $lines = @('[s3]', 'type = s3', "provider = $provider", 'env_auth = false', "access_key_id = $access", "secret_access_key = $secret", "region = $region", 'no_check_bucket = true')
            if ($endpoint) { $lines += "endpoint = $endpoint" }
            Set-Content -LiteralPath $rclone -Value (($lines -join "`n") + "`n") -Encoding utf8
            Set-DBPrivateFile $rclone
        }
        finally { $secret = $null }
    }
    $recipientsFile = Join-Path $SecretsRoot 'recipients.txt'
    $keep = Confirm-DBKeepSecret $recipientsFile 'destinatarios age'
    if ($keep) { $null = Read-DBRecipient $recipientsFile }
    else {
        # Validate before writing: an invalid file would otherwise be kept by the
        # next setup run.
        $recipients = $null
        for ($attempt = 1; $null -eq $recipients; $attempt++) {
            $answer = Read-DBValue 'Destinatarios age PUBLICOS (age1...), separados por virgula' ''
            try { $recipients = @(Get-DBRecipientList @($answer -split ',')) }
            catch {
                if ($attempt -ge 3) { throw }
                Write-Warning "$($_.Exception.Message) Tente novamente."
            }
        }
        Set-Content -LiteralPath $recipientsFile -Value $recipients -Encoding utf8
        Set-DBPrivateFile $recipientsFile
    }
}

function Read-DBToolPath {
    <# Asks a tool path (suggesting an installed one) until the file exists. #>
    param([Collections.IDictionary] $Tools, [string] $Key)
    $labels = @{
        MySql = 'Executavel mysql.exe'; MySqlDump = 'Executavel mysqldump.exe'; DbBackup = 'Executavel dbbackup.exe (SQL Anywhere)'
        SevenZip = 'Executavel 7z.exe'; Age = 'Executavel age.exe'; Rclone = 'Executavel rclone.exe'
    }
    $default = if ($Tools.Contains($Key)) { [string] $Tools[$Key] } else { '' }
    if (-not $default -or -not (Test-Path -LiteralPath $default -PathType Leaf)) {
        $candidate = Find-DBToolCandidate $Key
        if ($candidate) { $default = $candidate }
    }
    $Tools[$Key] = Read-DBRequiredValue $labels[$Key] $default {
        param($value)
        if (-not (Test-Path -LiteralPath $value -PathType Leaf)) { throw "Arquivo nao encontrado: $value" }
    }
}

function Find-DBCredentialCandidate {
    <# Existing credential files in Secrets for a provider that no job uses yet (*.cnf for MySQL, *.options for SQL Anywhere). #>
    param([string] $SecretsRoot, [string] $Provider, [string[]] $Assigned = @())
    if (-not (Test-Path -LiteralPath $SecretsRoot)) { return @() }
    $filter = if ($Provider -eq 'MySQL') { '*.cnf' } else { '*.options' }
    return @(Get-ChildItem -LiteralPath $SecretsRoot -File -Filter $filter | Where-Object { $_.FullName -notin $Assigned } | Sort-Object Name | ForEach-Object FullName)
}

function New-DBDatabaseCredential {
    <# Asks connection data and writes Secrets\<job>.cnf or .options (private). #>
    param([string] $Provider, [string] $Path, [string] $Database)
    $noSpaces = { param($value) if ($value -match '\s') { throw 'Nao use espacos.' } }
    if ($Provider -eq 'MySQL') {
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
        if ($Provider -eq 'MySQL') {
            $escape = { param($v) '"' + $v.Replace('\','\\').Replace('"','\"').Replace("`r",'\r').Replace("`n",'\n') + '"' }
            $content = "[client]`nhost=$(& $escape $hostName)`nport=$port`nuser=$(& $escape $user)`npassword=$(& $escape $password)`n"
        }
        else {
            foreach ($value in @($hostName, $server, $user, $password, $Database)) {
                if ($null -ne $value -and $value -match '["\r\n]') { throw 'SQL values cannot contain double quotes or newlines.' }
            }
            $location = if ($hostName) { "HOST='{0}'" -f $hostName.Replace("'","''") } else { "SERVER='{0}'" -f $server.Replace("'","''") }
            $content = '-c "UID=''{0}'';PWD=''{1}'';{2};DBN=''{3}''"' -f $user.Replace("'","''"), $password.Replace("'","''"), $location, $Database.Replace("'","''")
        }
        Set-Content -LiteralPath $Path -Value $content -Encoding utf8
        Set-DBPrivateFile $Path
    }
    finally { $password = $null; $content = $null }
}

function Read-DBDestination {
    <# Bucket and prefix of a job; Enter keeps the suggestion, '/' selects the bucket root. #>
    param([string] $RemoteName, [string] $DefaultBucket, [string] $DefaultPrefix, [string] $JobId)
    $bucket = Read-DBRequiredValue 'Bucket S3 deste job' $DefaultBucket {
        param($value)
        if ($value -cnotmatch '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$') { throw 'Nome de bucket invalido (minusculas, numeros, ponto e hifen; 3 a 63 caracteres).' }
    }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $prefix = (Read-DBValue 'Prefixo dentro do bucket (digite / para usar a raiz do bucket)' $DefaultPrefix).Trim('/')
        try {
            $root = ConvertTo-DBRemoteRoot $(if ($prefix) { "${RemoteName}:$bucket/$prefix" } else { "${RemoteName}:$bucket" })
            Write-DBSetupMessage "Destino: $root/$JobId/aaaa/mm/dd/"
            return $root
        }
        catch {
            if ($attempt -ge 3) { throw }
            Write-Warning "$($_.Exception.Message) Tente novamente."
        }
    }
}

function Read-DBJob {
    <#
    Asks one job of the given provider and returns @{ Job = <hashtable>; At = @('HH:mm', ...) }.
    Database credentials found in Secrets are offered before asking new ones.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'InstanceRoot', Justification = 'Read by the SourcePath validation scriptblock.')]
    [CmdletBinding()]
    param([string] $Provider, [Collections.IDictionary] $Data, [string] $SecretsRoot, [string] $InstanceRoot, [string[]] $UsedIds,
        [string[]] $AssignedSecretFiles, [string] $RemoteName, [string] $DefaultBucket, [string] $DefaultPrefix)
    $job = [ordered]@{ Provider = $Provider }
    $credential = $null
    if ($Provider -in @('MySQL','SQLAnywhere')) {
        if ($Provider -eq 'MySQL') { foreach ($key in @('MySql','MySqlDump')) { if (-not $Data.Tools.Contains($key) -or -not (Test-Path -LiteralPath $Data.Tools[$key] -PathType Leaf)) { Read-DBToolPath $Data.Tools $key } } }
        elseif (-not $Data.Tools.Contains('DbBackup') -or -not (Test-Path -LiteralPath $Data.Tools.DbBackup -PathType Leaf)) { Read-DBToolPath $Data.Tools 'DbBackup' }
        $kind = if ($Provider -eq 'MySQL') { 'credencial MySQL' } else { 'conexao SQL Anywhere' }
        foreach ($candidate in Find-DBCredentialCandidate $SecretsRoot $Provider $AssignedSecretFiles) {
            if (Read-DBConfirmation "Encontrado Secrets\$(Split-Path -Leaf $candidate) ($kind). Usar neste job?" $true) { $credential = $candidate; break }
        }
        $databaseDefault = ''
        if ($credential -and $Provider -eq 'SQLAnywhere') { $databaseDefault = (Read-DBSqlConnection $credential).DBN }
        $databasePrompt = if ($Provider -eq 'MySQL') { 'Nome do banco MySQL' } else { 'Nome do banco SQL Anywhere (DBN)' }
        $job.Database = Read-DBRequiredValue $databasePrompt $databaseDefault {
            param($value)
            if ($value -match '[\x00-\x1f"''\\/]' -or $value.Length -gt 128) { throw 'Nome de banco invalido.' }
        }
        if ($credential -and $Provider -eq 'SQLAnywhere' -and $job.Database -cne $databaseDefault) {
            Write-Warning "O DBN do arquivo $(Split-Path -Leaf $credential) ($databaseDefault) difere do banco informado; serao pedidas novas credenciais."
            $credential = $null
        }
        $idDefault = ConvertTo-DBJobId $job.Database $Provider.ToLowerInvariant()
    }
    else {
        $job.SourcePath = Read-DBRequiredValue 'Pasta a copiar (caminho completo)' '' {
            param($value)
            if (-not [IO.Path]::IsPathFullyQualified($value)) { throw 'Informe o caminho completo (ex.: D:\Documentos).' }
            if (-not (Test-Path -LiteralPath $value -PathType Container)) { throw "Pasta nao encontrada: $value" }
            $full = [IO.Path]::GetFullPath($value)
            if ((Test-DBPathWithin $full $InstanceRoot) -or (Test-DBPathWithin $InstanceRoot $full)) { throw 'A pasta nao pode conter nem estar dentro da instancia.' }
        }
        $idDefault = ConvertTo-DBJobId (Split-Path -Leaf ([IO.Path]::GetFullPath($job.SourcePath).TrimEnd('\','/'))) 'diretorio'
    }
    while ($idDefault -in $UsedIds) { $idDefault = "$idDefault-2" }
    $job.Id = Read-DBRequiredValue 'Identificador do job (nome da pasta no S3 e no Completed)' $idDefault {
        param($value)
        Assert-DBIdentifier $value
        if ($value -ieq 'logs') { throw "'logs' e reservado." }
        if (@($UsedIds | Where-Object { $_ -ieq $value }).Count) { throw "Ja existe um job $value nesta instancia." }
    }
    if ($Provider -in @('MySQL','SQLAnywhere')) {
        if (-not $credential) {
            $extension = if ($Provider -eq 'MySQL') { 'cnf' } else { 'options' }
            $credential = Join-Path $SecretsRoot "$($job.Id).$extension"
            if (Test-Path -LiteralPath $credential) { $credential = Join-Path $SecretsRoot "$($job.Id)-$([DateTime]::Now.ToString('yyyyMMddHHmmss')).$extension" }
            New-DBDatabaseCredential -Provider $Provider -Path $credential -Database $job.Database
        }
        else { Set-DBPrivateFile $credential }
        $job.CredentialFile = "Secrets/$(Split-Path -Leaf $credential)"
        if ($Provider -eq 'MySQL') { $job.ExtraArguments = @('--skip-events') }
    }
    $job.RemoteRoot = Read-DBDestination -RemoteName $RemoteName -DefaultBucket $DefaultBucket -DefaultPrefix $DefaultPrefix -JobId $job.Id
    $times = Read-DBRequiredValue 'Horarios diarios deste job (HH:mm; varios separados por virgula, ex.: 12:30,19:00)' '19:00' {
        param($value)
        $list = @(ConvertTo-DBTimeList $value)
        if (-not $list.Count) { throw 'Informe ao menos um horario.' }
    }
    return @{ Job = $job; At = @(ConvertTo-DBTimeList $times); Credential = $credential }
}

function ConvertTo-DBTimeList {
    <# '19:00' or '12:30, 19:00' -> sorted unique HH:mm list; throws on an invalid time. #>
    param([string] $Text)
    $times = @($Text -split '[,;\s]+' | Where-Object { $_ })
    foreach ($time in $times) { if ($time -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { throw "Horario invalido: $time. Use HH:mm, por exemplo 19:00." } }
    return @($times | Sort-Object -Unique)
}

function Add-DBScheduledJob {
    <#
    Puts a job in the daily task with exactly its times (diario-HHmm or
    diario-HHmm-HHmm...), creating the task when needed. One time is saved as
    At = 'HH:mm', several as At = @('HH:mm', ...).
    #>
    param([Collections.IDictionary] $Data, [string] $JobId, [string[]] $At)
    if (-not $Data.Contains('Schedule') -or $Data.Schedule -isnot [Collections.IDictionary]) { $Data.Schedule = @{ Tasks = @() } }
    $times = @($At | Sort-Object -Unique)
    $key = $times -join ','
    $tasks = @($Data.Schedule.Tasks)
    $match = @($tasks | Where-Object {
        $_ -is [Collections.IDictionary] -and (@($_.At | ForEach-Object { [string] $_ } | Sort-Object -Unique) -join ',') -eq $key -and
        (-not $_.Contains('Frequency') -or $_.Frequency -ceq 'Daily')
    })
    if ($match.Count -gt 0) { $match[0].Jobs = @($match[0].Jobs) + $JobId }
    else {
        $value = if ($times.Count -eq 1) { $times[0] } else { $times }
        $tasks += @{ Name = 'diario-' + (($times | ForEach-Object { $_.Replace(':', '') }) -join '-'); Jobs = @($JobId); At = $value; Frequency = 'Daily'; Enabled = $true }
    }
    $Data.Schedule.Tasks = $tasks
}

function Save-DBConfigurationData {
    <# Validates the data as a configuration, then writes config.psd1 atomically (inherited ACL). #>
    param([Collections.IDictionary] $Data, [string] $ConfigPath, [string] $InstancesRoot)
    $directory = Split-Path -Parent $ConfigPath
    $null = New-Item -ItemType Directory -Path $directory -Force
    $temp = Join-Path $directory "config-$([guid]::NewGuid().ToString('N')).tmp.psd1"
    try {
        $header = "# DBBackup 2.0 - instancia $($Data.InstanceName). Gerado pelo Setup; pode ser editado e reaplicado com Aplicar-Configuracao.bat.`n"
        Set-Content -LiteralPath $temp -Value ($header + (ConvertTo-DBDataLiteral $Data)) -Encoding utf8
        $candidate = Read-DBConfiguration $temp
        if ($InstancesRoot) {
            # Validate isolation as if the file were already config.psd1.
            $candidate.ConfigPath = $ConfigPath
            Assert-DBInstanceIsolation $candidate $InstancesRoot
        }
        [IO.File]::Move($temp, $ConfigPath, $true)
    }
    finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
    Restore-DBInheritedAccess $directory
    Restore-DBInheritedAccess $ConfigPath
}

function Invoke-DBInteractiveSetup {
    <#
    Guided creation (or extension) of an instance. Returns the config path.
    An existing 2.0 configuration can receive more jobs or just be reapplied;
    a 1.x configuration is kept as config.v1.psd1 and a new one is created.
    Secrets already in the instance folder are found and offered for reuse.
    #>
    param([string] $InstancesRoot, [string] $TemplateRoot, [string] $InstanceName)
    if (-not $InstanceName) {
        Write-DBSetupMessage 'A instancia agrupa jobs de backup (MySQL, SQL Anywhere, pastas) com as mesmas credenciais S3, chaves age e agenda.'
        $InstanceName = Read-DBRequiredValue 'Nome da instancia (ex.: assessoria)' '' { param($value) Assert-DBIdentifier $value }
    }
    Assert-DBIdentifier $InstanceName
    $instanceRoot = Join-Path ([IO.Path]::GetFullPath($InstancesRoot)) $InstanceName
    $configPath = Join-Path $instanceRoot 'config.psd1'
    $secretsRoot = Join-Path $instanceRoot 'Secrets'
    $data = $null
    if (Test-Path -LiteralPath $configPath) {
        $existing = Import-PowerShellDataFile -LiteralPath $configPath
        if ($existing.SchemaVersion -eq 2) {
            $null = Read-DBConfiguration $configPath
            if (-not (Read-DBConfirmation "A instancia $InstanceName ja existe. Adicionar jobs a ela? (Nao = apenas reaplicar)" $false)) { return $configPath }
            $data = $existing
        }
        else {
            $legacy = Join-Path $instanceRoot 'config.v1.psd1'
            if (Test-Path -LiteralPath $legacy) { $legacy = Join-Path $instanceRoot "config.v1-$([DateTime]::Now.ToString('yyyyMMddHHmmss')).psd1" }
            Move-Item -LiteralPath $configPath -Destination $legacy
            Write-DBSetupMessage "Configuracao 1.x guardada como $(Split-Path -Leaf $legacy). Os arquivos de Secrets serao oferecidos para reaproveitamento."
        }
    }
    if ($null -eq $data) {
        $data = Import-PowerShellDataFile -LiteralPath (Join-Path $TemplateRoot 'config.example.psd1')
        $data.InstanceName = $InstanceName
        $data.Jobs = @()
        $data.Schedule = @{ Tasks = @() }
    }
    Set-DBPrivateDirectory $secretsRoot -Force
    Restore-DBInheritedAccess $instanceRoot

    foreach ($key in @('SevenZip','Age','Rclone')) { Read-DBToolPath $data.Tools $key }
    Initialize-DBSharedSecret $secretsRoot
    $remoteName = Get-DBRcloneRemoteName (Join-Path $secretsRoot 'rclone.conf')

    $jobs = @($data.Jobs)
    $assigned = @($jobs | Where-Object { $_.Contains('CredentialFile') } | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $instanceRoot $_.CredentialFile)) })
    $lastBucket = ''
    $lastPrefix = $InstanceName.ToUpperInvariant()
    if ($jobs.Count) {
        $parts = Split-DBRemoteRoot ([string] $jobs[-1].RemoteRoot)
        if ($parts.Bucket) { $lastBucket = $parts.Bucket; $lastPrefix = $parts.Prefix }
    }
    $providers = @{ '1' = 'MySQL'; '2' = 'SQLAnywhere'; '3' = 'Directory' }
    $askedDirectory = $false
    while ($true) {
        $finish = if ($jobs.Count) { ', Enter = concluir' } else { '' }
        $choice = Read-DBValue "Adicionar job: 1 = MySQL, 2 = SQL Anywhere, 3 = Diretorio (pasta)$finish" ''
        if (-not $choice) {
            if (-not $jobs.Count) { Write-Warning 'Adicione ao menos um job.'; continue }
            if (-not $askedDirectory -and -not @($jobs | Where-Object { $_.Provider -eq 'Directory' }).Count) {
                $askedDirectory = $true
                if (Read-DBConfirmation 'Adicionar backup de diretorio (pasta) nesta instancia?' $false) { $choice = '3' } else { break }
            }
            else { break }
        }
        if (-not $providers.ContainsKey($choice)) { Write-Warning 'Opcao invalida.'; continue }
        $answer = Read-DBJob -Provider $providers[$choice] -Data $data -SecretsRoot $secretsRoot -InstanceRoot $instanceRoot -UsedIds @($jobs | ForEach-Object { [string] $_.Id }) `
            -AssignedSecretFiles $assigned -RemoteName $remoteName -DefaultBucket $lastBucket -DefaultPrefix $lastPrefix
        $jobs += $answer.Job
        if ($answer.Credential) { $assigned += [IO.Path]::GetFullPath($answer.Credential) }
        $parts = Split-DBRemoteRoot $answer.Job.RemoteRoot
        $lastBucket = $parts.Bucket
        $lastPrefix = if ($parts.Prefix) { $parts.Prefix } else { '/' }
        $data.Jobs = $jobs
        Add-DBScheduledJob $data $answer.Job.Id $answer.At
    }
    $data.Jobs = $jobs
    Save-DBConfigurationData $data $configPath $InstancesRoot
    Protect-DBInstanceSecret (Read-DBConfiguration $configPath)
    return $configPath
}

function Test-DBDatabaseConnection {
    <# Read-only connection probe of one job: MySQL SELECT 1 (lists visible databases on failure) or SQL Anywhere dbping -d. #>
    param([Collections.IDictionary] $Configuration, $Job, [double] $TimeoutSeconds = 60)
    if ($Job.Provider -eq 'MySQL') {
        $common = @("--defaults-extra-file=$($Job.CredentialFile)", '--batch', '--skip-column-names')
        $probe = Invoke-DBTool -Executable $Configuration.Tools.MySql -Arguments ($common + @("--database=$($Job.Database)", '--execute=SELECT 1')) -TimeoutSeconds $TimeoutSeconds
        if ($probe.ExitCode -eq 0) { return [pscustomobject]@{ Ok = $true; Message = "Banco $($Job.Database) acessivel." } }
        $detail = Protect-DBMessage ([string] $probe.StdErr).Trim()
        $list = Invoke-DBTool -Executable $Configuration.Tools.MySql -Arguments ($common + @('--execute=SHOW DATABASES')) -TimeoutSeconds $TimeoutSeconds
        if ($list.ExitCode -eq 0) {
            $names = @(([string] $list.StdOut) -split "`r?`n" | Where-Object { $_ -and $_ -notin @('information_schema','performance_schema','mysql','sys') })
            return [pscustomobject]@{ Ok = $false; Message = "Conectou, mas o banco $($Job.Database) nao esta acessivel ($detail). Bancos visiveis: $($names -join ', ')" }
        }
        return [pscustomobject]@{ Ok = $false; Message = "Falha ao conectar no MySQL: $detail" }
    }
    $dbping = Join-Path (Split-Path -Parent $Configuration.Tools.DbBackup) 'dbping.exe'
    if (-not (Test-Path -LiteralPath $dbping -PathType Leaf)) { return [pscustomobject]@{ Ok = $true; Message = 'dbping.exe nao encontrado ao lado do dbbackup.exe; teste do banco ignorado.' } }
    $connection = Read-DBSqlConnection $Job.CredentialFile
    $connection.ASTART = 'NO'
    $options = Join-Path $Configuration.SecretsRoot "dbping-$([guid]::NewGuid().ToString('N')).options"
    try {
        Write-DBSqlOption $options $connection
        $probe = Invoke-DBTool -Executable $dbping -Arguments @('-d', "@$options") -TimeoutSeconds $TimeoutSeconds
        if ($probe.ExitCode -eq 0) { return [pscustomobject]@{ Ok = $true; Message = "Banco $($Job.Database) acessivel." } }
        $detail = ConvertTo-DBSafeToolOutput -Text "$($probe.StdOut) $($probe.StdErr)" -Secret $connection.PWD
        return [pscustomobject]@{ Ok = $false; Message = "Falha ao conectar no SQL Anywhere: $detail" }
    }
    finally { if (Test-Path -LiteralPath $options) { Remove-Item -LiteralPath $options -Force } }
}

function Invoke-DBConnectionCheck {
    <#
    Optional, read-only checks before tasks are applied: database login of each
    database job and S3 listing of each destination. Writes nothing to buckets.
    Returns $false when a check failed and the operator chose to stop.
    #>
    param([Collections.IDictionary] $Configuration)
    if (-not (Read-DBConfirmation 'Testar agora a conexao com os bancos e com o S3 (somente leitura)?' $true)) { return $true }
    $results = @()
    foreach ($job in @($Configuration.Jobs | Where-Object Provider -In @('MySQL','SQLAnywhere'))) {
        try { $results += [pscustomobject]@{ Name = "Banco ($($job.Id))"; Result = (Test-DBDatabaseConnection -Configuration $Configuration -Job $job) } }
        catch { $results += [pscustomobject]@{ Name = "Banco ($($job.Id))"; Result = [pscustomobject]@{ Ok = $false; Message = (Protect-DBMessage $_.Exception.Message) } } }
    }
    foreach ($job in @($Configuration.Jobs | Where-Object Provider -EQ 'Directory')) {
        $ok = Test-Path -LiteralPath $job.SourcePath -PathType Container
        $results += [pscustomobject]@{ Name = "Pasta ($($job.Id))"; Result = [pscustomobject]@{ Ok = $ok; Message = $(if ($ok) { "$($job.SourcePath) encontrada." } else { "$($job.SourcePath) nao encontrada." }) } }
    }
    foreach ($root in @($Configuration.Jobs | ForEach-Object RemoteRoot | Select-Object -Unique)) {
        try { $results += [pscustomobject]@{ Name = "S3 ($root)"; Result = (Test-DBStorageAccess -RclonePath $Configuration.Tools.Rclone -ConfigPath $Configuration.Storage.ConfigPath -RemoteRoot $root -TimeoutSeconds 120) } }
        catch { $results += [pscustomobject]@{ Name = "S3 ($root)"; Result = [pscustomobject]@{ Ok = $false; Message = (Protect-DBMessage $_.Exception.Message) } } }
    }
    foreach ($entry in $results) {
        $mark = if ($entry.Result.Ok) { 'OK  ' } else { 'FALHA' }
        Write-DBSetupMessage "[$mark] $($entry.Name): $($entry.Result.Message)"
    }
    if (@($results | Where-Object { -not $_.Result.Ok }).Count -eq 0) { return $true }
    return (Read-DBConfirmation 'Algum teste falhou. Continuar mesmo assim e aplicar a configuracao?' $false)
}

function Get-DBSetupSummary {
    <# Lines for the operator at the end of setup. RegisteredTasks are the tasks found in the scheduler afterwards. #>
    param([Collections.IDictionary] $Configuration, [AllowEmptyCollection()][string[]] $RegisteredTasks = @(), [string] $PwshPath, [string] $ScriptPath)
    $recipients = @(Read-DBRecipient $Configuration.Encryption.RecipientsFile)
    $lines = @(
        '', '===== Resumo do DBBackup ====='
        "Instancia:         $($Configuration.InstanceName)"
        "Configuracao:      $($Configuration.ConfigPath)"
        "Destinatarios age: $($recipients.Count)"
        "Completed / Logs:  $($Configuration.Paths.CompletedRoot) / $($Configuration.Paths.LogRoot)"
        'Diagnostico local: OK'
    )
    foreach ($job in $Configuration.Jobs) {
        $source = if ($job.Provider -eq 'Directory') { $job.SourcePath } else { "banco $($job.Database)" }
        $lines += "Job $($job.Id): $($job.Provider), $source -> $($job.Destination)/aaaa/mm/dd/"
    }
    $scheduled = @(Get-DBScheduleTask $Configuration)
    if ($scheduled.Count -eq 0) { $lines += 'Agenda:            nenhuma tarefa' }
    foreach ($task in $scheduled) {
        $state = if ($task.RegisteredName -in $RegisteredTasks) { 'registrada' } else { 'NAO registrada' }
        $lines += "Tarefa:            $(Get-DBTaskFolder)$($task.RegisteredName) - $($task.Frequency) $(@($task.At) -join ', '), jobs $(@($task.Jobs) -join ', ') ($state)"
    }
    $lines += ''
    $lines += 'Proximo passo: rode um backup manual (Executar-Backup.bat) e confira os arquivos no bucket:'
    $lines += "  & `"$PwshPath`" -NoProfile -File `"$ScriptPath`" -ConfigPath `"$($Configuration.ConfigPath)`" -All"
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
    # 2.0 permissions: instance folder and config.psd1 inherit the installation
    # ACL (editable by operators); Secrets and Runtime stay private.
    Restore-DBInheritedAccess $Configuration.InstanceRoot
    Restore-DBInheritedAccess $Configuration.ConfigPath
    Protect-DBInstanceSecret $Configuration
    # Runtime inside the instance folder belongs to DBBackup: it is always made
    # private (2.0 refused when permissions had been inherited). A Runtime set
    # elsewhere must already be private or empty; it is never rewritten.
    if (Test-DBPathWithin $Configuration.Paths.RuntimeRoot $Configuration.InstanceRoot) { Set-DBPrivateDirectory $Configuration.Paths.RuntimeRoot -Force }
    else { Set-DBPrivateDirectory $Configuration.Paths.RuntimeRoot -Enforce }
    foreach ($path in @($Configuration.Paths.CompletedRoot, $Configuration.Paths.LogRoot)) { $null = New-Item -ItemType Directory -Path $path -Force }
    $null = Test-DBInstance $Configuration $InstancesRoot
    if ($Configuration.Contains('Schedule')) { Invoke-DBScheduleApply -Configuration $Configuration -ScriptPath $ScriptPath -PwshPath $PwshPath }
    Invoke-DBLegacyTaskCleanup
}

function Edit-DBConfiguration {
    <#
    Editar-Configuracao.bat: opens config.psd1 in an editor running elevated
    (so Save writes the file, no "Save as"), waits for it to close and
    validates the file. Returns $true when it is valid and the operator wants
    to apply it now. An invalid file can be reopened or put back as it was.
    #>
    param([Parameter(Mandatory)][string] $ConfigPath, [Parameter(Mandatory)][string] $InstancesRoot, [string] $Editor = 'notepad.exe')
    $original = [IO.File]::ReadAllBytes($ConfigPath)
    while ($true) {
        Write-DBSetupMessage "Abrindo $ConfigPath no editor. Salve (Ctrl+S) e feche o editor para continuar."
        $watch = [Diagnostics.Stopwatch]::StartNew()
        Start-Process -FilePath $Editor -ArgumentList "`"$ConfigPath`"" -Wait
        # Some editors (Notepad of Windows 11) return at once; wait for the operator then.
        if ($watch.Elapsed.TotalSeconds -lt 3) { $null = Read-Host 'Depois de salvar e fechar o editor, pressione Enter' }
        $changed = -not [Linq.Enumerable]::SequenceEqual([byte[]] $original, [byte[]] [IO.File]::ReadAllBytes($ConfigPath))
        try {
            $configuration = Read-DBConfiguration $ConfigPath
            Assert-DBInstanceIsolation $configuration $InstancesRoot
            $null = Get-DBScheduleTask $configuration
        }
        catch {
            Write-Warning "Configuracao invalida: $(Protect-DBMessage $_.Exception.Message)"
            Write-DBSetupMessage 'Enquanto o arquivo estiver invalido, os backups agendados desta instancia terminam com erro de configuracao (exit 2).'
            if (Read-DBConfirmation 'Abrir o arquivo de novo para corrigir?' $true) { continue }
            if (Read-DBConfirmation 'Voltar o arquivo para como estava antes da edicao?' $true) {
                [IO.File]::WriteAllBytes($ConfigPath, $original)
                Write-DBSetupMessage 'Arquivo restaurado; nada foi aplicado.'
                return $false
            }
            throw 'Configuracao invalida; nada foi aplicado.'
        }
        if (-not $changed) {
            Write-DBSetupMessage 'O arquivo nao foi alterado.'
            return (Read-DBConfirmation 'Aplicar a configuracao mesmo assim?' $false)
        }
        Write-DBSetupMessage 'Configuracao valida.'
        if (Read-DBConfirmation 'Aplicar agora (permissoes, diagnostico e tarefas agendadas)?' $true) { return $true }
        Write-DBSetupMessage 'Alteracoes salvas, mas nao aplicadas: as tarefas agendadas so mudam depois de Aplicar-Configuracao.bat.'
        return $false
    }
}

function Invoke-DBLegacyTaskCleanup {
    <# Offers to delete tasks of DBBackup 0.x/1.x, which keep running the old installation. #>
    try { $legacy = @(Get-DBLegacyTask) }
    catch { Write-Warning "Nao foi possivel procurar tarefas de versoes anteriores: $(Protect-DBMessage $_.Exception.Message)"; return }
    if ($legacy.Count -eq 0) { return }
    Write-DBSetupMessage ''
    Write-DBSetupMessage 'Tarefas de versoes anteriores do DBBackup encontradas. Elas nao sao gerenciadas por esta versao e continuam executando a instalacao antiga:'
    foreach ($task in $legacy) { Write-DBSetupMessage "  $($task.Folder)\$($task.Name)  ->  $($task.Arguments)" }
    if ((Read-Host 'Remover estas tarefas antigas? Digite SIM') -cne 'SIM') { Write-DBSetupMessage 'Tarefas antigas mantidas.'; return }
    Remove-DBLegacyTask $legacy
    Write-DBSetupMessage "$($legacy.Count) tarefa(s) antiga(s) removida(s)."
}

function Invoke-DBScheduleApply {
    param([Collections.IDictionary] $Configuration, [string] $ScriptPath, [string] $PwshPath)
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

Export-ModuleMember -Function Edit-DBConfiguration, Read-DBConfirmation, ConvertTo-DBTimeList, Invoke-DBInteractiveSetup, Invoke-DBConfigurationApply, Test-DBInstance, ConvertTo-DBDataLiteral, Invoke-DBConnectionCheck, Test-DBDatabaseConnection, Get-DBOwnedTask, Get-DBSetupSummary, Split-DBRemoteRoot, Initialize-DBSharedSecret, Read-DBJob, Add-DBScheduledJob, Save-DBConfigurationData, ConvertTo-DBJobId, Find-DBCredentialCandidate, Restore-DBInheritedAccess
