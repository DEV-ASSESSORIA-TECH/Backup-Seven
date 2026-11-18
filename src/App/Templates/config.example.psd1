# DBBackup 2.0 - configuracao de uma instancia (schema 2).
# O Setup.bat gera este arquivo; este modelo documenta o formato e fornece
# os valores padrao. Instancia = contexto (credenciais S3, destinatarios age,
# agenda, lock e pastas). Cada job e uma fonte com provedor e destino proprios.
@{
    SchemaVersion = 2
    InstanceName = 'REPLACE_INSTANCE'
    Tools = @{
        SevenZip = 'C:\Program Files\7-Zip\7z.exe'
        Age = 'C:\Program Files\age\age.exe'
        Rclone = 'C:\Program Files\rclone\rclone.exe'
        # Somente quando houver jobs desses provedores:
        # MySql = 'C:\Program Files\MySQL\MySQL Server 5.5\bin\mysql.exe'
        # MySqlDump = 'C:\Program Files\MySQL\MySQL Server 5.5\bin\mysqldump.exe'
        # DbBackup = 'C:\Program Files\SQL Anywhere 17\Bin64\dbbackup.exe'
    }
    # Exemplos de jobs (RemoteRoot = remote:bucket/prefixo; o arquivo vai para
    # <RemoteRoot>/<Id>/aaaa/mm/dd/):
    # @{ Id = 'seven'; Provider = 'MySQL'; Database = 'a_estoque'; CredentialFile = 'Secrets/seven.cnf'
    #    ExtraArguments = @('--skip-events'); RemoteRoot = 's3:assessoriatech-backups-seven-prod/ASSESSORIA' }
    # @{ Id = 'dominio'; Provider = 'SQLAnywhere'; Database = 'contabil'; CredentialFile = 'Secrets/dominio.options'
    #    RemoteRoot = 's3:bucket-dominio/ASSESSORIA' }
    # @{ Id = 'documentos'; Provider = 'Directory'; SourcePath = 'D:\Documentos'; RemoteRoot = 's3:bucket/ASSESSORIA' }
    Jobs = @()
    Execution = @{ ToolTimeoutSeconds = 21600; RunTimeoutSeconds = 39600; ReserveBytes = 1073741824; EstimatedDatabaseBytes = 0 }
    Storage = @{ ConfigPath = 'Secrets/rclone.conf'; Destination = 's3' }
    Encryption = @{ RecipientsFile = 'Secrets/recipients.txt' }
    # Paths omitido: Runtime fica na instancia; Completed e Logs em
    # <raiz>\Completed\<instancia> e <raiz>\Logs\<instancia>.
    Archive = @{ CompressionLevel = 5; CpuLimitPercent = 50 }
    Retention = @{ CompletedDays = 7; LogDays = 30; KeepLocalPayload = $true }
    Monitoring = @{ Enabled = $false; Service = 'erp'; TextfileDirectory = 'C:\ProgramData\GrafanaLabs\Alloy\textfile\backup'; BackupIds = @{} }
    # Tarefas: Jobs de uma tarefa rodam em sequencia na mesma execucao.
    # @{ Name = 'diario-1900'; Jobs = @('seven','dominio'); At = '19:00'; Frequency = 'Daily' }
    Schedule = @{ Tasks = @() }
}
