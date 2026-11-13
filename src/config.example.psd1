@{
    # Stable customer/site name used in file names and remote paths.
    InstanceName = 'MULTI-COPIAS'

    Tools = @{
        MySqlDump = 'C:\Program Files\MySQL\MySQL Server 5.5\bin\mysqldump.exe'
        MySql     = 'C:\Program Files\MySQL\MySQL Server 5.5\bin\mysql.exe'
        SevenZip   = 'C:\Program Files\7-Zip\7z.exe'
        Rclone     = 'C:\Program Files\rclone\rclone.exe'
    }

    Database = @{
        Name = 'a_estoque'

        # The package includes a placeholder file. Fill it on the server and
        # protect it with NTFS ACLs. Expected format:
        # [client]
        # host=REPLACE_WITH_MYSQL_HOST
        # port=3306
        # user=REPLACE_WITH_BACKUP_USER
        # password=REPLACE_WITH_BACKUP_PASSWORD
        DefaultsExtraFile = 'C:\TI\Scripts\BackupSeven\Secrets\mysql-backup.cnf'

        # The current account cannot read MySQL events. Remove this switch only
        # after granting EVENT and validating a real dump with scheduled events.
        ExtraArguments = @(
            '--skip-events'
        )
    }

    Fiscal = @{
        SourcePath = 'C:\Seven Sistemas\Fiscal'
    }

    Storage = @{
        ConfigPath = 'C:\TI\Scripts\BackupSeven\Secrets\rclone.conf'
        RemoteRoot = 's3:assessoriatech-backups-seven-prod'
    }

    Archive = @{
        CompressionLevel = 5
        CpuLimitPercent  = 50
    }

    Paths = @{
        RuntimeRoot = 'C:\TI\Scripts\BackupSeven\Runtime'
        CompletedRoot = 'C:\TI\Scripts\BackupSeven\Completed'
        LogRoot     = 'C:\TI\Scripts\BackupSeven\Logs'
    }

    Retention = @{
        CompletedDays = 7
        LogDays       = 30
    }

    # Optional. Writes the generic backup state read by Grafana Alloy (job
    # integrations/backup). Remove the section or set Enabled = $false to turn
    # it off. A failure to write never changes the backup exit code.
    Monitoring = @{
        Enabled = $true

        # Created by the Alloy installer (servidor profile). BackupSeven never
        # creates it; if it is missing, the run only logs a warning.
        TextfileDirectory = 'C:\ProgramData\GrafanaLabs\Alloy\textfile\backup'

        # Identity of each backup: <Service>__<BackupId>.prom.
        Service = 'seven'
        BackupIds = @{
            Database = 'database'
            Fiscal   = 'fiscal'
        }

        # Largest expected gap between successful backups. With runs at 12:00
        # and 19:00, the gap from 19:00 to 12:00 is 17 hours.
        ExpectedIntervalHours = @{
            Database = 17
            Fiscal   = 17
        }
    }
}
