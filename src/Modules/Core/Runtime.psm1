Set-StrictMode -Version Latest

function Protect-DBMessage {
    param([AllowNull()][string] $Message)
    if ($null -eq $Message) { return '' }
    return (($Message -replace '(?i)((?:password|pwd|secret_access_key|access_key_id)\s*[=:]\s*)(?:"[^"]*"|''[^'']*''|[^;\s]+)', '$1[REDACTED]') -replace '[\r\n]+', ' ')
}

function Set-DBPrivateDirectory {
    param([Parameter(Mandatory)][string] $Path)
    $null = New-Item -ItemType Directory -Path $Path -Force
    if ($IsWindows) {
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
            $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.SecurityIdentifier]::new($sid), 'FullControl',
                'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
    }
}

function New-DBRuntime {
    param([Collections.IDictionary] $Configuration)
    foreach ($path in $Configuration.Paths.Values) { Set-DBPrivateDirectory $path }
    $runtime = $Configuration.Paths.RuntimeRoot
    foreach ($name in @('Pending', 'Work', 'Staging')) { Set-DBPrivateDirectory (Join-Path $runtime $name) }
    try {
        $lock = [IO.File]::Open((Join-Path $runtime 'DBBackup.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    }
    catch [IO.IOException] { return $null }
    $id = [guid]::NewGuid().ToString('N')
    $work = Join-Path $runtime "Work/$id"
    try {
        Set-DBPrivateDirectory $work
        return [pscustomobject]@{
            RunId = $id; Lock = $lock; Work = $work
            Pending = Join-Path $runtime 'Pending'; Staging = Join-Path $runtime 'Staging'
            Completed = $Configuration.Paths.CompletedRoot
            LogPath = Join-Path $Configuration.Paths.LogRoot "DBBackupLog_$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))_$id.log"
        }
    }
    catch { $lock.Dispose(); throw }
}

function Write-DBLog {
    param([string] $Path, [string] $Stage, [string] $Message, [ValidateSet('INFO','WARN','ERROR')][string] $Level = 'INFO')
    $line = '{0} [{1}] [{2}] {3}' -f [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Stage, (Protect-DBMessage $Message)
    [IO.File]::AppendAllText($Path, $line + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}

function Close-DBRuntime {
    param($Runtime)
    try {
        if (Test-Path -LiteralPath $Runtime.Work) {
            # Work is an exact generated GUID directory, never a configured root.
            if ((Split-Path -Leaf $Runtime.Work) -cne $Runtime.RunId -or $Runtime.RunId -notmatch '^[a-f0-9]{32}$') { throw 'Unsafe work path.' }
            Remove-Item -LiteralPath $Runtime.Work -Recurse -Force -ErrorAction Stop
        }
    }
    finally { $Runtime.Lock.Dispose() }
}

Export-ModuleMember -Function Protect-DBMessage, Set-DBPrivateDirectory, New-DBRuntime, Write-DBLog, Close-DBRuntime
