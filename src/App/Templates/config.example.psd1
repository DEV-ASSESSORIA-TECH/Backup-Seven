# DBBackup 2.2 - configuracao de uma instancia (schema 2).
# O menu (DBBackup.bat, opcao 1) gera este arquivo; este modelo documenta o
# formato. Instancia = contexto (credenciais S3, destinatarios age, agenda,
# lock e pastas). Cada job e uma fonte com provedor e destino proprios.
# Ferramentas e padroes do servidor ficam em <raiz>\ambiente.psd1; uma secao
# Tools, Execution, Archive ou Retention aqui so e necessaria para mudar o
# valor do ambiente nesta instancia.
@{
    SchemaVersion = 2
    InstanceName = 'REPLACE_INSTANCE'
    # Exemplos de jobs (RemoteRoot = remote:bucket/prefixo; o arquivo vai para
    # <RemoteRoot>/<Id>/aaaa/mm/dd/; incrementais em <RemoteRoot>/<Id>/incremental/aaaa/mm/dd/):
    # @{ Id = 'seven'; Provider = 'MySQL'; Database = 'a_estoque'; CredentialFile = 'Secrets/seven.cnf'
    #    ExtraArguments = @('--skip-events'); RemoteRoot = 's3:assessoriatech-backups-seven-prod/ASSESSORIA' }
    # @{ Id = 'dominio'; Provider = 'SQLAnywhere'; Database = 'contabil'; CredentialFile = 'Secrets/dominio.options'
    #    RemoteRoot = 's3:bucket-dominio/ASSESSORIA'; Incremental = @{ Enabled = $true; KeepRenamedLogDays = 3 } }
    # @{ Id = 'documentos'; Provider = 'Directory'; SourcePath = 'D:\Documentos'; RemoteRoot = 's3:bucket/ASSESSORIA' }
    Jobs = @()
    Storage = @{ ConfigPath = 'Secrets/rclone.conf'; Destination = 's3' }
    Encryption = @{ RecipientsFile = 'Secrets/recipients.txt' }
    # Paths omitido: Runtime fica na instancia; Completed e Logs em
    # <raiz>\Completed\<instancia> e <raiz>\Logs\<instancia>.
    Monitoring = @{ Enabled = $false; Service = 'erp'; BackupIds = @{} }
    # Tarefas: Jobs de uma tarefa rodam em sequencia na mesma execucao.
    # @{ Name = 'diario-1900'; Jobs = @('seven','dominio'); At = '19:00'; Frequency = 'Daily' }
    # Varios horarios na mesma tarefa: At = @('12:30', '19:00')
    # Incremental (jobs com Incremental.Enabled): Mode = 'Incremental'
    # @{ Name = 'incremental'; Jobs = @('dominio'); Mode = 'Incremental'; At = @('09:00','12:00','15:00','18:00') }
    Schedule = @{ Tasks = @() }
}
