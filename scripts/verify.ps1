#requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$version = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'VERSION must be X.Y.Z.' }
if (-not (Select-String -LiteralPath (Join-Path $root 'CHANGELOG.md') -Pattern "^## \[$([regex]::Escape($version))\]" -Quiet)) { throw 'CHANGELOG release entry is missing.' }
$parseFailed = $false
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'src'), (Join-Path $root 'scripts'), (Join-Path $root 'tests') -Recurse -File -Include *.ps1,*.psm1,*.psd1) {
    $tokens = $null
    $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $tokens, [ref] $parseErrors)
    foreach ($parseError in $parseErrors) { Write-Error "$($file.FullName): $($parseError.Message)" -ErrorAction Continue; $parseFailed = $true }
}
if ($parseFailed) { throw 'PowerShell parsing failed.' }
$issues = @()
foreach ($path in @('src','scripts','tests')) {
    $issues += Invoke-ScriptAnalyzer -Path (Join-Path $root $path) -Recurse -Severity Warning,Error -ExcludeRule PSUseShouldProcessForStateChangingFunctions
}
if ($issues.Count) { $issues | Format-Table RuleName,ScriptName,Line,Message -Wrap; throw 'Static analysis failed.' }
$configuration = New-PesterConfiguration
$configuration.Run.Path = Join-Path $root 'tests'
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Detailed'
# These tests do not use the registry. Pester otherwise creates an HKCU test
# hive unconditionally, which is unnecessary under the development sandbox.
$configuration.TestRegistry.Enabled = $false
$result = Invoke-Pester -Configuration $configuration
if ($result.FailedCount -or $result.FailedContainersCount) { throw 'DBBackup verification failed.' }
