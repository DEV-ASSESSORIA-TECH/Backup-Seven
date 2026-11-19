Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Configuration.psm1')

<#
Versioned configurations: the repository keeps, per server,
configuracoes/<servidor>/ambiente.psd1 and
configuracoes/<servidor>/<instancia>/config.psd1. Only these two kinds of file
travel; Secrets (rclone.conf, recipients.txt, credentials) never do.
#>

function Get-DBVersionedFile {
    <# Local versionable files as @{ Relative = 'ambiente.psd1' | '<inst>/config.psd1'; Path = <full> }. #>
    param([Parameter(Mandatory)][string] $InstallRoot)
    $files = @()
    $environment = Join-Path $InstallRoot 'ambiente.psd1'
    if (Test-Path -LiteralPath $environment -PathType Leaf) { $files += [pscustomobject]@{ Relative = 'ambiente.psd1'; Path = $environment } }
    $instances = Join-Path $InstallRoot 'Instances'
    foreach ($config in @(Get-ChildItem -Path (Join-Path $instances '*/config.psd1') -File -ErrorAction SilentlyContinue | Sort-Object FullName)) {
        $files += [pscustomobject]@{ Relative = "$(Split-Path -Leaf $config.DirectoryName)/config.psd1"; Path = $config.FullName }
    }
    return $files
}

function Get-DBVersionedLocalPath {
    <# Local path of a repository-relative name; only ambiente.psd1 and <instance>/config.psd1 are accepted. #>
    param([Parameter(Mandatory)][string] $InstallRoot, [Parameter(Mandatory)][string] $Relative)
    if ($Relative -ceq 'ambiente.psd1') { return Join-Path $InstallRoot 'ambiente.psd1' }
    if ($Relative -match '^(?<instance>[^/\\]+)/config\.psd1$') {
        Assert-DBIdentifier $Matches.instance
        return Join-Path (Join-Path (Join-Path $InstallRoot 'Instances') $Matches.instance) 'config.psd1'
    }
    throw "Arquivo nao versionavel: $Relative"
}

function Assert-DBNoSecretText {
    <# A versioned file holds paths to Secrets, never their content. #>
    param([string] $Text, [string] $Name)
    if ($Text -match '(?im)\b(PWD|password|secret_access_key|access_key_id)\s*[=:]|AGE-SECRET-KEY-') { throw "$Name parece conter um segredo; nada foi exportado ou gravado." }
}

function Export-DBVersionedConfiguration {
    <# Copies ambiente.psd1 and every config.psd1 to <Destination>\<server>\ for a commit in configuracoes/. #>
    param([Parameter(Mandatory)][string] $InstallRoot, [Parameter(Mandatory)][string] $Destination, [Parameter(Mandatory)][string] $ServerName)
    Assert-DBIdentifier $ServerName
    $target = Join-Path $Destination $ServerName
    $files = @(Get-DBVersionedFile $InstallRoot)
    if (-not $files.Count) { throw 'Nenhuma configuracao encontrada para exportar.' }
    foreach ($file in $files) { Assert-DBNoSecretText (Get-Content -LiteralPath $file.Path -Raw) $file.Relative }
    foreach ($file in $files) {
        $path = Join-Path $target $file.Relative
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
        Copy-Item -LiteralPath $file.Path -Destination $path -Force
    }
    return [pscustomobject]@{ Path = $target; Files = @($files.Relative) }
}

function Get-DBRemoteVersionedFile {
    <#
    Lists configuracoes/<server>/ of the repository branch through the GitHub
    contents API (public repository, no token) and downloads each versionable
    file. Returns @{ Relative; Text }.
    #>
    param([Parameter(Mandatory)][string] $Repository, [Parameter(Mandatory)][string] $ServerName,
        [string] $Branch = 'main', [string] $ApiBaseUrl = 'https://api.github.com')
    Assert-DBIdentifier $ServerName
    $headers = @{ Accept = 'application/vnd.github+json' }
    $base = "$ApiBaseUrl/repos/$Repository/contents/configuracoes/$ServerName"
    try { $entries = @(Invoke-RestMethod -Uri "${base}?ref=$Branch" -Headers $headers -TimeoutSec 60) }
    catch { throw "Nao foi possivel ler configuracoes/$ServerName em $Repository ($Branch): $($_.Exception.Message)" }
    $result = @()
    foreach ($entry in $entries) {
        if ($entry.type -eq 'file' -and $entry.name -ceq 'ambiente.psd1') { $result += [pscustomobject]@{ Relative = 'ambiente.psd1'; Url = $entry.download_url } }
        elseif ($entry.type -eq 'dir') {
            Assert-DBIdentifier $entry.name
            foreach ($child in @(Invoke-RestMethod -Uri "$base/$($entry.name)?ref=$Branch" -Headers $headers -TimeoutSec 60)) {
                if ($child.type -eq 'file' -and $child.name -ceq 'config.psd1') { $result += [pscustomobject]@{ Relative = "$($entry.name)/config.psd1"; Url = $child.download_url } }
            }
        }
    }
    foreach ($item in $result) {
        $text = [string] (Invoke-WebRequest -Uri $item.Url -TimeoutSec 60 -UseBasicParsing).Content
        Assert-DBNoSecretText $text $item.Relative
        $item | Add-Member -NotePropertyName Text -NotePropertyValue $text
    }
    return $result
}

function Compare-DBVersionedFile {
    <# Remote files that differ from (or do not exist in) the installation, with a line diff. #>
    param([Parameter(Mandatory)][string] $InstallRoot, [object[]] $Remote)
    $changes = @()
    foreach ($item in @($Remote)) {
        $local = Get-DBVersionedLocalPath $InstallRoot $item.Relative
        $current = if (Test-Path -LiteralPath $local -PathType Leaf) { Get-Content -LiteralPath $local -Raw } else { $null }
        $normalize = { param($text) @(([string] $text) -split '\r?\n' | ForEach-Object { $_.TrimEnd() }) }
        $before = & $normalize $current
        $after = & $normalize $item.Text
        if ($null -ne $current -and (($before -join "`n").TrimEnd() -ceq ($after -join "`n").TrimEnd())) { continue }
        $diff = if ($null -eq $current) { @('(arquivo novo)') } else {
            @(Compare-Object -ReferenceObject $before -DifferenceObject $after -CaseSensitive | ForEach-Object { if ($_.SideIndicator -eq '=>') { "+ $($_.InputObject)" } else { "- $($_.InputObject)" } })
        }
        $changes += [pscustomobject]@{ Relative = $item.Relative; Path = $local; Text = $item.Text; New = ($null -eq $current); Diff = $diff }
    }
    return $changes
}

function Install-DBVersionedFile {
    <#
    Writes the changed files (the previous copy stays as <file>.anterior), then
    validates ambiente.psd1 and every touched instance. Any failure puts all
    files back as they were. Returns the instances whose config changed.
    #>
    param([Parameter(Mandatory)][string] $InstallRoot, [Parameter(Mandatory)][object[]] $Changes)
    $written = @()
    try {
        foreach ($change in $Changes) {
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $change.Path) -Force
            $backup = "$($change.Path).anterior"
            if (-not $change.New) { Copy-Item -LiteralPath $change.Path -Destination $backup -Force }
            $temp = "$($change.Path).$([guid]::NewGuid().ToString('N')).tmp"
            [IO.File]::WriteAllText($temp, $change.Text, [Text.UTF8Encoding]::new($true))
            [IO.File]::Move($temp, $change.Path, $true)
            $written += $change
        }
        $environment = Join-Path $InstallRoot 'ambiente.psd1'
        if (Test-Path -LiteralPath $environment) { $null = Read-DBEnvironment $environment }
        $instances = @()
        foreach ($change in @($Changes | Where-Object { $_.Relative -ne 'ambiente.psd1' })) { $instances += Split-Path -Leaf (Split-Path -Parent $change.Path) }
        $checked = if (@($Changes | Where-Object Relative -EQ 'ambiente.psd1').Count) { @(Get-DBVersionedFile $InstallRoot | Where-Object Relative -NE 'ambiente.psd1') } else { @($Changes | Where-Object Relative -NE 'ambiente.psd1') }
        foreach ($item in $checked) {
            # A new instance has no Secrets yet: its file is checked by the setup later.
            if (@($Changes | Where-Object { $_.Path -eq $item.Path -and $_.New }).Count) { continue }
            try { $null = Read-DBConfiguration $item.Path }
            catch { throw "$($item.Relative): $($_.Exception.Message)" }
        }
        return $instances
    }
    catch {
        foreach ($change in $written) {
            if ($change.New) { Remove-Item -LiteralPath $change.Path -Force -ErrorAction SilentlyContinue }
            else { Copy-Item -LiteralPath "$($change.Path).anterior" -Destination $change.Path -Force }
        }
        throw "Configuracao do repositorio invalida; nada foi alterado. $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function Get-DBVersionedFile, Get-DBVersionedLocalPath, Assert-DBNoSecretText, Export-DBVersionedConfiguration, Get-DBRemoteVersionedFile, Compare-DBVersionedFile, Install-DBVersionedFile
