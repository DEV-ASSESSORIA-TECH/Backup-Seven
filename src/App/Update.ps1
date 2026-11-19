#requires -Version 7.2
<#
Updates a DBBackup installation in place. DBBackup.bat (menu option 8) runs a temporary copy
of this file, so the App folder (and this script) can be replaced.

Without -PackagePath: asks GitHub for the latest release, downloads the ZIP
and its .sha256 and verifies the checksum. With -PackagePath: uses a ZIP that
was downloaded by hand (offline servers; drag the ZIP onto DBBackup.bat).

Only App\ and the files at the package root (.bat, LEIA-ME.txt) are replaced.
Instances\ (config.psd1, Secrets, Runtime), Completed\ and Logs\ are never
touched. The previous App\ and root files are kept in
Versoes-Anteriores\<version>_<timestamp>\ (the three newest are kept) and are
restored automatically when the replacement fails.

The script is self-contained (no module imports) so the temporary copy works
while App\ is being replaced. Dot-sourcing it only defines the functions.
#>
[CmdletBinding()]
param(
    [string] $InstallRoot,
    [string] $PackagePath,
    [string] $Repository = 'DEV-ASSESSORIA-TECH/DBBackup',
    [string] $ApiBaseUrl = 'https://api.github.com',
    # No questions: update when newer and do not reapply configurations.
    [switch] $Yes
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:PreviousFolderName = 'Versoes-Anteriores'
$script:KeepPrevious = 3
# Operational state that a package must never contain and an update never touches.
$script:ProtectedNames = @('Instances', 'Completed', 'Logs', 'Versoes-Anteriores')

function ConvertTo-DBReleaseVersion {
    <# 'v2.1.0' / '2.1.0' -> [version] 2.1.0; anything else throws. #>
    param([Parameter(Mandatory)][string] $Text)
    $value = $Text.Trim()
    if ($value -match '^[vV]') { $value = $value.Substring(1) }
    if ($value -notmatch '^\d+\.\d+\.\d+$') { throw "Versao invalida: $Text" }
    return [version] $value
}

function Get-DBInstalledVersion {
    param([Parameter(Mandatory)][string] $InstallRoot)
    $path = Join-Path $InstallRoot 'App/VERSION'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Instalacao do DBBackup nao encontrada em $InstallRoot (falta App\VERSION)." }
    return ConvertTo-DBReleaseVersion (Get-Content -LiteralPath $path -Raw)
}

function Get-DBLatestRelease {
    <# Latest published release (drafts and pre-releases are excluded by GitHub). #>
    param([string] $Repository, [string] $ApiBaseUrl)
    $uri = '{0}/repos/{1}/releases/latest' -f $ApiBaseUrl.TrimEnd('/'), $Repository
    $release = Invoke-RestMethod -Uri $uri -Headers @{ Accept = 'application/vnd.github+json' } -TimeoutSec 60
    $version = ConvertTo-DBReleaseVersion ([string] $release.tag_name)
    $zipName = "DBBackup-$version.zip"
    $assets = @($release.assets)
    $zip = @($assets | Where-Object { $_.name -ceq $zipName })
    $sha = @($assets | Where-Object { $_.name -ceq "$zipName.sha256" })
    if ($zip.Count -ne 1 -or $sha.Count -ne 1) { throw "A release $($release.tag_name) nao tem os arquivos $zipName e $zipName.sha256." }
    [pscustomobject]@{
        Version = $version; Tag = [string] $release.tag_name; Url = [string] $release.html_url
        ZipName = $zipName; ZipUrl = [string] $zip[0].browser_download_url; ShaUrl = [string] $sha[0].browser_download_url
    }
}

function Assert-DBPackageChecksum {
    <# The .sha256 file is "<hex>  <file name>"; the ZIP must match it. #>
    param([Parameter(Mandatory)][string] $ZipPath, [Parameter(Mandatory)][string] $ChecksumPath)
    $expected = ((Get-Content -LiteralPath $ChecksumPath -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
    if ($expected -notmatch '^[a-f0-9]{64}$') { throw 'Arquivo .sha256 invalido.' }
    $actual = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne $expected) { throw "Checksum do pacote nao confere (esperado $expected, obtido $actual). Nada foi alterado." }
}

function Expand-DBUpdatePackage {
    <#
    Extracts the ZIP into an empty directory and checks that it is a DBBackup
    package: App\VERSION, App\Setup.ps1, App\Backup.ps1 and DBBackup.bat present,
    nothing but App\, .bat files and LEIA-ME.txt at the root. Returns the version.
    #>
    param([Parameter(Mandatory)][string] $ZipPath, [Parameter(Mandatory)][string] $Destination)
    $null = New-Item -ItemType Directory -Path $Destination -Force
    if (@(Get-ChildItem -LiteralPath $Destination -Force).Count) { throw 'A pasta de extracao precisa estar vazia.' }
    # .NET refuses entries that would land outside the destination.
    [IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $Destination)
    foreach ($required in @('App/VERSION', 'App/Setup.ps1', 'App/Backup.ps1', 'DBBackup.bat')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Destination $required) -PathType Leaf)) { throw "O ZIP nao e um pacote do DBBackup (falta $required)." }
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $Destination -Force)) {
        $allowed = ($item.PSIsContainer -and $item.Name -ceq 'App') -or
            (-not $item.PSIsContainer -and ($item.Extension -ieq '.bat' -or $item.Name -ceq 'LEIA-ME.txt'))
        if (-not $allowed) { throw "O pacote contem um item inesperado na raiz: $($item.Name). Nada foi alterado." }
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $Destination -Recurse -Force)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'O pacote contem um link; nada foi alterado.' }
    }
    return ConvertTo-DBReleaseVersion (Get-Content -LiteralPath (Join-Path $Destination 'App/VERSION') -Raw)
}

function Get-DBRunningInstance {
    <#
    Instances whose backup is running now: a run holds Runtime\DBBackup.lock
    open without sharing. An absent lock file means no run.
    #>
    param([Parameter(Mandatory)][string] $InstallRoot)
    $instances = Join-Path $InstallRoot 'Instances'
    if (-not (Test-Path -LiteralPath $instances -PathType Container)) { return @() }
    $busy = @()
    foreach ($directory in @(Get-ChildItem -LiteralPath $instances -Directory -Force)) {
        $lock = Join-Path $directory.FullName 'Runtime/DBBackup.lock'
        if (-not (Test-Path -LiteralPath $lock -PathType Leaf)) { continue }
        try { [IO.File]::Open($lock, 'Open', 'ReadWrite', 'None').Dispose() }
        catch [IO.FileNotFoundException] { continue }
        catch [IO.IOException] { $busy += $directory.Name }
    }
    return $busy
}

function Get-DBPackageRootFile {
    <# Files at the root of an installation or package that an update replaces. #>
    param([Parameter(Mandatory)][string] $Root)
    return @(Get-ChildItem -LiteralPath $Root -File -Force | Where-Object { $_.Extension -ieq '.bat' -or $_.Name -ceq 'LEIA-ME.txt' })
}

function Copy-DBDirectory {
    param([Parameter(Mandatory)][string] $Source, [Parameter(Mandatory)][string] $Destination)
    $null = New-Item -ItemType Directory -Path $Destination -Force
    foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force)) {
        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $Destination $item.Name) -Recurse -Force -ErrorAction Stop
    }
}

function Save-DBPreviousVersion {
    <# Copies App\ and the root files to Versoes-Anteriores\<version>_<stamp>\; returns that folder. #>
    param([Parameter(Mandatory)][string] $InstallRoot, [Parameter(Mandatory)][version] $Version)
    $stamp = [DateTime]::Now.ToString('yyyy-MM-dd_HH-mm-ss', [Globalization.CultureInfo]::InvariantCulture)
    $target = Join-Path (Join-Path $InstallRoot $script:PreviousFolderName) "${Version}_$stamp"
    for ($n = 2; (Test-Path -LiteralPath $target) -and $n -lt 100; $n++) { $target = Join-Path (Join-Path $InstallRoot $script:PreviousFolderName) "${Version}_$stamp-$n" }
    Copy-DBDirectory -Source (Join-Path $InstallRoot 'App') -Destination (Join-Path $target 'App')
    foreach ($file in Get-DBPackageRootFile $InstallRoot) { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $target $file.Name) -Force -ErrorAction Stop }
    return $target
}

function Set-DBInstalledFile {
    <# Replaces App\ by the one in Source and copies the root files of Source. #>
    param([Parameter(Mandatory)][string] $InstallRoot, [Parameter(Mandatory)][string] $Source)
    $app = Join-Path $InstallRoot 'App'
    if (Test-Path -LiteralPath $app) { Remove-Item -LiteralPath $app -Recurse -Force -ErrorAction Stop }
    Copy-DBDirectory -Source (Join-Path $Source 'App') -Destination $app
    foreach ($file in Get-DBPackageRootFile $Source) { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $InstallRoot $file.Name) -Force -ErrorAction Stop }
}

function Remove-DBOldPreviousVersion {
    param([Parameter(Mandatory)][string] $InstallRoot, [int] $Keep = $script:KeepPrevious)
    $root = Join-Path $InstallRoot $script:PreviousFolderName
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return }
    $old = @(Get-ChildItem -LiteralPath $root -Directory -Force | Where-Object { $_.Name -match '^\d+\.\d+\.\d+_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}(-\d+)?$' } |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -Skip $Keep)
    foreach ($directory in $old) { Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction Stop }
}

function Install-DBUpdate {
    <#
    Saves the current version, then replaces App\ and the root files. On any
    failure the saved copy is put back and the error is rethrown. Returns the
    folder with the previous version.
    #>
    param([Parameter(Mandatory)][string] $InstallRoot, [Parameter(Mandatory)][string] $Staging, [Parameter(Mandatory)][version] $CurrentVersion)
    $previous = Save-DBPreviousVersion -InstallRoot $InstallRoot -Version $CurrentVersion
    try { Set-DBInstalledFile -InstallRoot $InstallRoot -Source $Staging }
    catch {
        $failure = $_.Exception.Message
        try { Set-DBInstalledFile -InstallRoot $InstallRoot -Source $previous }
        catch { throw "Falha ao atualizar ($failure) e ao restaurar a versao anterior ($($_.Exception.Message)). Copie manualmente $previous para $InstallRoot." }
        throw "Falha ao atualizar; a versao $CurrentVersion foi restaurada. Detalhe: $failure"
    }
    try { Remove-DBOldPreviousVersion -InstallRoot $InstallRoot }
    catch { Write-Warning "Versoes anteriores antigas nao foram removidas: $($_.Exception.Message)" }
    return $previous
}

function Read-DBUpdateConfirmation {
    param([string] $Prompt, [bool] $Default, [switch] $Yes)
    if ($Yes) { return $Default }
    $suffix = if ($Default) { 'S/n' } else { 's/N' }
    $answer = Read-Host "$Prompt [$suffix]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim() -match '^(?i:s|sim|y|yes)$'
}

function Invoke-DBUpdate {
    <# Exit codes: 0 updated, already current or cancelled; 1 failure; 3 a backup is running. #>
    param([string] $InstallRoot, [string] $PackagePath, [string] $Repository = 'DEV-ASSESSORIA-TECH/DBBackup',
        [string] $ApiBaseUrl = 'https://api.github.com', [switch] $Yes)
    $work = $null
    try {
        if (-not $InstallRoot) { throw 'Informe -InstallRoot (pasta com App\ e os arquivos .bat).' }
        $root = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\', '/')
        $current = Get-DBInstalledVersion $root
        "DBBackup instalado: $current ($root)" | Out-Host
        $work = Join-Path ([IO.Path]::GetTempPath()) "DBBackup-update-$([guid]::NewGuid().ToString('N'))"
        $null = New-Item -ItemType Directory -Path $work
        if ($PackagePath) {
            $zip = [IO.Path]::GetFullPath($PackagePath.Trim('"'))
            if (-not (Test-Path -LiteralPath $zip -PathType Leaf)) { throw "Pacote nao encontrado: $zip" }
            $checksum = "$zip.sha256"
            if (Test-Path -LiteralPath $checksum -PathType Leaf) { Assert-DBPackageChecksum $zip $checksum; 'Checksum do pacote conferido.' | Out-Host }
            else { Write-Warning "Arquivo $(Split-Path -Leaf $checksum) nao encontrado ao lado do ZIP; o checksum nao sera conferido." }
            $source = "pacote $zip"
        }
        else {
            'Consultando a ultima versao no GitHub...' | Out-Host
            try { $release = Get-DBLatestRelease -Repository $Repository -ApiBaseUrl $ApiBaseUrl }
            catch {
                throw "Nao foi possivel consultar o GitHub ($($_.Exception.Message)). Sem internet: baixe DBBackup-X.Y.Z.zip e .sha256 da pagina de releases e arraste o ZIP sobre o DBBackup.bat."
            }
            "Ultima versao publicada: $($release.Version) - $($release.Url)" | Out-Host
            if ($release.Version -le $current) { "Ja esta na versao mais recente ($current). Nada a fazer." | Out-Host; return 0 }
            if (-not (Read-DBUpdateConfirmation -Yes:$Yes "Atualizar de $current para $($release.Version)?" $true)) { 'Atualizacao cancelada.' | Out-Host; return 0 }
            $zip = Join-Path $work $release.ZipName
            $checksum = "$zip.sha256"
            'Baixando o pacote...' | Out-Host
            Invoke-WebRequest -Uri $release.ZipUrl -OutFile $zip -TimeoutSec 600
            Invoke-WebRequest -Uri $release.ShaUrl -OutFile $checksum -TimeoutSec 60
            Assert-DBPackageChecksum $zip $checksum
            'Checksum do pacote conferido.' | Out-Host
            $source = "release $($release.Tag)"
        }
        $staging = Join-Path $work 'package'
        $target = Expand-DBUpdatePackage -ZipPath $zip -Destination $staging
        if ($PackagePath) {
            if ($target -lt $current) { Write-Warning "O pacote ($target) e mais antigo que a versao instalada ($current)." }
            $prompt = if ($target -eq $current) { "Reinstalar a versao $current a partir do ${source}?" } else { "Instalar a versao $target a partir do ${source}?" }
            if (-not (Read-DBUpdateConfirmation -Yes:$Yes $prompt ($target -gt $current))) { 'Atualizacao cancelada.' | Out-Host; return 0 }
        }
        $busy = @(Get-DBRunningInstance $root)
        if ($busy.Count) {
            Write-Error "Backup em execucao nas instancias: $($busy -join ', '). Aguarde terminar e rode a atualizacao de novo. Nada foi alterado." -ErrorAction Continue
            return 3
        }
        $previous = Install-DBUpdate -InstallRoot $root -Staging $staging -CurrentVersion $current
        "DBBackup atualizado de $current para $target." | Out-Host
        "Versao anterior guardada em $previous" | Out-Host
        'Instances (configuracoes e Secrets), Completed e Logs nao foram alterados.' | Out-Host
        $configs = @()
        $instances = Join-Path $root 'Instances'
        if (Test-Path -LiteralPath $instances) { $configs = @(Get-ChildItem -Path (Join-Path $instances '*/config.psd1') -File -ErrorAction SilentlyContinue | Sort-Object FullName) }
        if ($configs.Count -and -not $Yes -and (Read-DBUpdateConfirmation -Yes:$Yes "Reaplicar a configuracao das $($configs.Count) instancia(s) com a versao nova (recomendado)?" $true)) {
            $pwsh = (Get-Process -Id $PID).Path
            foreach ($config in $configs) {
                "`n== Aplicando $($config.FullName)" | Out-Host
                & $pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'App/Setup.ps1') -Apply -ConfigPath $config.FullName
                if ($LASTEXITCODE -ne 0) { Write-Warning "Aplicacao terminou com codigo $LASTEXITCODE; use Aplicar no menu (DBBackup.bat) para esta instancia." }
            }
        }
        return 0
    }
    catch {
        Write-Error $_.Exception.Message -ErrorAction Continue
        return 1
    }
    finally {
        if ($work -and (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

if ($MyInvocation.InvocationName -eq '.') { return }
exit (Invoke-DBUpdate -InstallRoot $InstallRoot -PackagePath $PackagePath -Repository $Repository -ApiBaseUrl $ApiBaseUrl -Yes:$Yes)
