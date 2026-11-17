#requires -Version 7.0
[CmdletBinding()]
param([string] $OutputDirectory)
if ($OutputDirectory) { Write-Verbose "Requested output: $OutputDirectory" }
throw 'DBBackup v1 packaging is intentionally unavailable until recovery review and release qualification (implementation step 9).'
