# DBBackup 2.2 - ambiente do servidor (<raiz>\ambiente.psd1).
# Vale para todas as instancias desta instalacao; uma instancia pode
# sobrescrever qualquer valor na propria configuracao. Alterar so como
# Administrador (DBBackup.bat, opcao 7): a tarefa agendada roda como SYSTEM os
# executaveis indicados aqui.
@{
    SchemaVersion = 1
    Tools = @{
        SevenZip = 'C:\Program Files\7-Zip\7z.exe'
        Age = 'C:\Program Files\age\age.exe'
        Rclone = 'C:\Program Files\rclone\rclone.exe'
        # Somente quando houver jobs desses provedores:
        # MySql = 'C:\Program Files\MySQL\MySQL Server 5.5\bin\mysql.exe'
        # MySqlDump = 'C:\Program Files\MySQL\MySQL Server 5.5\bin\mysqldump.exe'
        # Pasta com dbbackup.exe e dbping.exe (...\Tools ou ...\Bin64):
        # SqlAnywhere = 'C:\Program Files\SQL Anywhere 17\Tools'
    }
    Execution = @{ ToolTimeoutSeconds = 21600; RunTimeoutSeconds = 39600; ReserveBytes = 1073741824; EstimatedDatabaseBytes = 0 }
    Archive = @{ CompressionLevel = 5; CpuLimitPercent = 50 }
    Retention = @{ CompletedDays = 7; LogDays = 30; KeepLocalPayload = $true }
    # Site: label site das metricas (local do servidor); o setup pergunta.
    # Monitoring = @{ TextfileDirectory = '...'; Site = 'assessoria' }
    Monitoring = @{ TextfileDirectory = 'C:\ProgramData\GrafanaLabs\Alloy\textfile\backup' }
}
