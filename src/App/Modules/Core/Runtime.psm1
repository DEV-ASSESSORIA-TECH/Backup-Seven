Set-StrictMode -Version Latest

function Protect-DBMessage {
    param([AllowNull()][string] $Message)
    if ($null -eq $Message) { return '' }
    return (($Message -replace '(?i)((?:password|pwd|secret_access_key|access_key_id)\s*[=:]\s*)(?:"[^"]*"|''[^'']*''|[^;\s]+)', '$1[REDACTED]') -replace '[\r\n]+', ' ')
}

function Test-DBPrivateAccess {
    param([Parameter(Mandatory)][string] $Path)
    if (-not $IsWindows) { return $true }
    # Effective rules, inherited ones included (a child of a private instance
    # directory is private); SIDs avoid name translation of orphaned accounts.
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin @('S-1-5-18', 'S-1-5-32-544')) { return $false }
    }
    return $true
}

function Set-DBPrivateDirectory {
    <#
    Default: create the directory when missing and protect only what was created;
    an existing directory is never rewritten by a backup run.
    -Enforce (setup): an existing directory must already be private or be empty.
    -Force (setup): the directory belongs to DBBackup (instance/Secrets) and is
    always made private.
    #>
    param([Parameter(Mandatory)][string] $Path, [switch] $Enforce, [switch] $Force)
    $existed = Test-Path -LiteralPath $Path
    if ($existed -and -not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Path is not a directory: $Path" }
    $null = New-Item -ItemType Directory -Path $Path -Force
    if (-not $IsWindows) { return }
    if ($existed -and -not $Force) {
        if (-not $Enforce) { return }
        if (Test-DBPrivateAccess $Path) { return }
        if (@(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop).Count -gt 0) {
            throw "Existing directory is not private and is not empty; refusing to replace its permissions: $Path. Use a dedicated directory for DBBackup state."
        }
    }
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

function New-DBLogPath {
    <# Logs\<instance>\yyyy-MM-dd_HH-mm-ss.log in local time; -2, -3... if taken. #>
    param([string] $LogRoot)
    $stamp = [DateTime]::Now.ToString('yyyy-MM-dd_HH-mm-ss', [Globalization.CultureInfo]::InvariantCulture)
    $path = Join-Path $LogRoot "$stamp.log"
    for ($n = 2; (Test-Path -LiteralPath $path) -and $n -lt 1000; $n++) { $path = Join-Path $LogRoot "$stamp-$n.log" }
    return $path
}

function New-DBRuntime {
    param([Collections.IDictionary] $Configuration)
    # Runtime holds plaintext work and pending bundles: private. Completed
    # (encrypted bundles) and Logs (sanitized) are operator folders and keep
    # the permissions inherited from the installation.
    Set-DBPrivateDirectory $Configuration.Paths.RuntimeRoot
    foreach ($path in @($Configuration.Paths.CompletedRoot, $Configuration.Paths.LogRoot)) { $null = New-Item -ItemType Directory -Path $path -Force }
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
            LogPath = New-DBLogPath $Configuration.Paths.LogRoot
        }
    }
    catch { $lock.Dispose(); throw }
}

function Write-DBLog {
    param([string] $Path, [string] $Stage, [string] $Message, [ValidateSet('INFO','WARN','ERROR')][string] $Level = 'INFO')
    $line = '{0} [{1}] [{2}] {3}' -f [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Stage, (Protect-DBMessage $Message)
    [IO.File]::AppendAllText($Path, $line + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}

function Clear-DBStaleRuntime {
    <#
    Runs while the instance lock is held, so no other run of this instance can
    own Work or Staging content. Removes plaintext payloads and transient
    credentials left by interrupted runs. Only generated names are removed;
    Pending (complete encrypted bundles awaiting upload) is never touched.
    #>
    param([Parameter(Mandatory)] $Runtime)
    $removed = @()
    $skipped = @()
    $targets = @(
        @{ Root = (Split-Path -Parent $Runtime.Work); Pattern = '^[a-f0-9]{32}$' }
        # 2.0 names start with the local timestamp; DBBackup_* covers 1.x leftovers.
        @{ Root = $Runtime.Staging; Pattern = '^(DBBackup_[A-Za-z0-9_-]+|\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_[A-Za-z0-9_-]+)$' }
    )
    foreach ($target in $targets) {
        if (-not (Test-Path -LiteralPath $target.Root -PathType Container)) { continue }
        foreach ($item in @(Get-ChildItem -LiteralPath $target.Root -Force -ErrorAction Stop)) {
            if ($item.FullName -eq $Runtime.Work) { continue }
            if (-not $item.PSIsContainer -or $item.Name -cnotmatch $target.Pattern -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                $skipped += $item.FullName
                continue
            }
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
            $removed += $item.FullName
        }
    }
    [pscustomobject]@{ Removed = $removed; Skipped = $skipped }
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

Export-ModuleMember -Function Protect-DBMessage, Test-DBPrivateAccess, Set-DBPrivateDirectory, New-DBRuntime, Write-DBLog, Clear-DBStaleRuntime, Close-DBRuntime
