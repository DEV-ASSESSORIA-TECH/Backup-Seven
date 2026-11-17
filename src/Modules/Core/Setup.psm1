Set-StrictMode -Version Latest
foreach ($name in @('Configuration','Runtime','Artifacts','Schedule','Capacity','Encryption')) { Import-Module (Join-Path $PSScriptRoot "$name.psm1") }
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

function Read-DBValue {
    param([string] $Prompt, [string] $Default)
    $answer = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    if ($answer -match '[\r\n]') { throw 'Newlines are not accepted.' }
    return $answer
}

function Read-DBSecret {
    param([string] $Prompt)
    $secure = Read-Host $Prompt -AsSecureString
    try { return [Net.NetworkCredential]::new('', $secure).Password }
    finally { $secure.Dispose() }
}

function Set-DBInteractiveConfiguration {
    param([string] $ConfigPath)
    $data = Import-PowerShellDataFile -LiteralPath $ConfigPath
    foreach ($name in @($data.Tools.Keys | Sort-Object)) { $data.Tools[$name] = Read-DBValue "Executavel $name" $data.Tools[$name] }
    $data.Database.Name = Read-DBValue 'Nome do banco' $data.Database.Name
    $data.Storage.RemoteRoot = Read-DBValue 'Destino rclone remote:bucket/prefix' $data.Storage.RemoteRoot
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
        $hostName = Read-DBValue 'Host do banco (SQL Anywhere: host:porta)' 'localhost'
        $user = Read-DBValue 'Usuario de backup' 'backup'
        $password = Read-DBSecret 'Senha do banco'
        try {
            if ($Configuration.Provider -eq 'MySQL') {
                $port = Read-DBValue 'Porta MySQL' '3306'
                if ($port -notmatch '^\d+$' -or [int] $port -notin 1..65535) { throw 'Invalid MySQL port.' }
                $escape = { param($v) '"' + $v.Replace('\','\\').Replace('"','\"').Replace("`r",'\r').Replace("`n",'\n') + '"' }
                $content = "[client]`nhost=$(& $escape $hostName)`nport=$port`nuser=$(& $escape $user)`npassword=$(& $escape $password)`n"
            }
            else {
                foreach ($value in @($hostName, $user, $password, $Configuration.Database.Name)) {
                    if ($value -match '["\r\n]') { throw 'SQL values cannot contain double quotes or newlines.' }
                }
                $content = '-c "UID=''{0}'';PWD=''{1}'';HOST=''{2}'';DBN=''{3}''"' -f $user.Replace("'","''"), $password.Replace("'","''"), $hostName.Replace("'","''"), $Configuration.Database.Name.Replace("'","''")
            }
            Set-Content -LiteralPath $dbFile -Value $content -Encoding utf8
            Set-DBPrivateFile $dbFile
        }
        finally { $password = $null; $content = $null }
    }
    if (-not (Test-Path -LiteralPath $Configuration.Storage.ConfigPath)) {
        $remote = $Configuration.Storage.RemoteRoot.Split(':')[0]
        $provider = Read-DBValue 'Provedor S3 do rclone (AWS, Wasabi, Minio, Cloudflare, Other...)' 'AWS'
        if ($provider -cnotmatch '^[A-Za-z0-9]+$') { throw 'Invalid rclone S3 provider name.' }
        $endpoint = Read-DBValue 'Endpoint S3 (vazio para o padrao do provedor)' ''
        if ($endpoint -match '\s') { throw 'The S3 endpoint cannot contain spaces.' }
        $access = Read-DBValue 'Access key ID' ''
        $secret = Read-DBSecret 'Secret access key'
        $region = Read-DBValue 'Regiao' 'us-east-1'
        try {
            foreach ($value in @($access, $secret, $region)) { if ($value -match '[\r\n]') { throw 'Newlines in S3 settings are not accepted.' } }
            $lines = @("[$remote]", 'type = s3', "provider = $provider", 'env_auth = false', "access_key_id = $access", "secret_access_key = $secret", "region = $region")
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

function Invoke-DBConfigurationApply {
    param([Collections.IDictionary] $Configuration, [string] $InstancesRoot, [string] $ScriptPath,
        [string] $PwshPath, [switch] $PlanOnly)
    Assert-DBInstanceIsolation $Configuration $InstancesRoot
    if ($PlanOnly) {
        # Read-only: no ACL changes, directory creation, credentials or probes.
        $tasks = @()
        if ($Configuration.Contains('Schedule')) { $tasks = @(Get-DBSchedulerSnapshot (Get-DBTaskFolder $Configuration.InstanceName)) }
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
    $folder = Get-DBTaskFolder $Configuration.InstanceName
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

Export-ModuleMember -Function Initialize-DBInstance, Set-DBInteractiveConfiguration, Initialize-DBSecret, Invoke-DBConfigurationApply, Test-DBInstance, ConvertTo-DBDataLiteral
