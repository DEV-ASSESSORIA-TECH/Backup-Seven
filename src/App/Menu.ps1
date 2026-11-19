#requires -Version 7.2
<#
Operator menu (DBBackup.bat). Each option runs the existing script in a child
pwsh, so an error or exit there returns to the menu. Exit code 10 asks
DBBackup.bat to run the updater (it replaces App\ and the .bat itself).
#>
[CmdletBinding()]
param(
    [string] $InstallRoot = (Split-Path -Parent $PSScriptRoot),
    [string] $Repository = 'DEV-ASSESSORIA-TECH/DBBackup'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$instancesRoot = Join-Path $InstallRoot 'Instances'
$pwsh = (Get-Process -Id $PID).Path

function Invoke-DBMenuScript {
    param([string] $Script, [string[]] $Arguments = @())
    & $pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $Script) @Arguments
    $code = $LASTEXITCODE
    if ($code -ne 0) { Write-Warning "Terminou com codigo $code." }
}

function Show-DBLastResult {
    <# Last RESULTADO line of the newest run log of each instance. #>
    $logs = Join-Path $InstallRoot 'Logs'
    $found = $false
    foreach ($directory in @(Get-ChildItem -LiteralPath $logs -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $runs = @(Get-ChildItem -LiteralPath $directory.FullName -File -Filter '*.log' | Where-Object Name -Match '^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}' | Sort-Object Name -Descending | Select-Object -First 5)
        foreach ($run in $runs) {
            $line = @(Select-String -LiteralPath $run.FullName -Pattern 'RESULTADO: ' -SimpleMatch | Select-Object -Last 1)
            $text = if ($line.Count) { $line[0].Line.Substring($line[0].Line.IndexOf('RESULTADO: ')) } else { '(sem resultado: em andamento ou interrompida)' }
            '{0,-14} {1}  {2}' -f $directory.Name, $run.BaseName, $text | Out-Host
            $found = $true
        }
    }
    if (-not $found) { 'Nenhum log de execucao encontrado em Logs\.' | Out-Host }
}

function Invoke-DBVersionedMenu {
    param([string] $GitHubRepository)
    Import-Module (Join-Path $PSScriptRoot 'Modules/Core/ConfigSync.psm1')
    $server = $env:COMPUTERNAME
    $server = if ($server) { $server.ToLowerInvariant() } else { [Environment]::MachineName.ToLowerInvariant() }
    $answer = ([string] (Read-Host "Configuracoes (configuracoes/$server no repositorio): 1 = puxar do GitHub, 2 = exportar para commit, 3 = padronizar formatacao, Enter = voltar")).Trim()
    if ($answer -eq '3') {
        if (([string] (Read-Host 'Reescrever ambiente.psd1 e os config.psd1 no formato padrao? Os dados nao mudam; comentarios escritos a mao sao perdidos (copia em <arquivo>.anterior) (s/N)')).Trim() -notmatch '^(s|sim)$') { return }
        & $pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Setup.ps1') -Format
        return
    }
    if ($answer -eq '2') {
        $exported = Export-DBVersionedConfiguration -InstallRoot $InstallRoot -Destination (Join-Path $InstallRoot 'Configuracoes-Exportadas') -ServerName $server
        "Exportado para $($exported.Path):" | Out-Host
        $exported.Files | ForEach-Object { "  $_" } | Out-Host
        "Copie a pasta $server para configuracoes/ no repositorio e faca o commit na main. Secrets nunca sao exportados." | Out-Host
        return
    }
    if ($answer -ne '1') { return }
    $remote = @(Get-DBRemoteVersionedFile -Repository $GitHubRepository -ServerName $server)
    if (-not $remote.Count) { "Nada em configuracoes/$server no repositorio." | Out-Host; return }
    $changes = @(Compare-DBVersionedFile -InstallRoot $InstallRoot -Remote $remote)
    if (-not $changes.Count) { 'As configuracoes locais ja estao iguais as do repositorio.' | Out-Host; return }
    foreach ($change in $changes) {
        "`n== $($change.Relative)" | Out-Host
        $change.Diff | Select-Object -First 60 | Out-Host
    }
    $confirm = ([string] (Read-Host "`nGravar estes $($changes.Count) arquivo(s)? A copia anterior fica como <arquivo>.anterior (s/N)")).Trim()
    if ($confirm -notmatch '^(s|sim|y|yes)$') { 'Nada foi alterado.' | Out-Host; return }
    $instances = @(Install-DBVersionedFile -InstallRoot $InstallRoot -Changes $changes)
    'Configuracoes gravadas e validadas.' | Out-Host
    foreach ($change in @($changes | Where-Object New)) {
        if ($change.Relative -ne 'ambiente.psd1') { "Instancia nova $($change.Relative): crie os Secrets pelo menu, opcao 1 (mesmo nome), antes de aplicar." | Out-Host }
    }
    $apply = if (@($changes | Where-Object Relative -EQ 'ambiente.psd1').Count) {
        @(Get-ChildItem -Path (Join-Path $instancesRoot '*/config.psd1') -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    } else { @($instances | ForEach-Object { Join-Path (Join-Path $instancesRoot $_) 'config.psd1' }) }
    $apply = @($apply | Where-Object { $path = $_; -not @($changes | Where-Object { $_.New -and $_.Path -eq $path }).Count })
    if ($apply.Count -and ([string] (Read-Host "Aplicar agora $($apply.Count) instancia(s)? (S/n)")).Trim() -notmatch '^(n|nao)$') {
        foreach ($config in $apply) { Invoke-DBMenuScript 'Setup.ps1' @('-Apply', '-ConfigPath', $config) }
    }
}

$version = try { (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'VERSION') -Raw).Trim() } catch { '?' }
while ($true) {
    Clear-Host
    @(
        "DBBackup $version - $InstallRoot"
        ''
        '  1  Nova instancia / adicionar jobs'
        '  2  Editar configuracao de uma instancia'
        '  3  Aplicar configuracao (permissoes, diagnostico, tarefas)'
        '  4  Diagnosticar'
        '  5  Executar backup agora (completo ou incremental)'
        '  6  Ultimos resultados'
        '  7  Ambiente do servidor (ferramentas e padroes)'
        '  8  Atualizar o DBBackup'
        '  9  Configuracoes (puxar do GitHub, exportar, padronizar formatacao)'
        '  0  Sair'
        ''
    ) | Out-Host
    $choice = ([string] (Read-Host 'Opcao')).Trim()
    if (-not $choice) { continue }
    try {
        switch ($choice) {
            '1' { Invoke-DBMenuScript 'Setup.ps1' }
            '2' { Invoke-DBMenuScript 'Setup.ps1' @('-Edit') }
            '3' { Invoke-DBMenuScript 'Setup.ps1' @('-Apply') }
            '4' { Invoke-DBMenuScript 'Diagnose.ps1' }
            '5' { Invoke-DBMenuScript 'Backup.ps1' @('-Interactive') }
            '6' { Show-DBLastResult }
            '7' { Invoke-DBMenuScript 'Setup.ps1' @('-Environment') }
            '8' { exit 10 }
            '9' { Invoke-DBVersionedMenu -GitHubRepository $Repository }
            '0' { exit 0 }
            default { Write-Warning 'Opcao invalida.' }
        }
    }
    catch { Write-Warning $_.Exception.Message }
    $null = Read-Host "`nEnter para voltar ao menu"
}
