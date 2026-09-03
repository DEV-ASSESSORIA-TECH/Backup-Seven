@{
    # Stable name used to separate servers in file names and remote paths.
    InstanceName = 'SEVEN-SERVER'

    Tools = @{
        MySqlDump = 'C:\Seven Sistemas\MySQL\bin\mysqldump.exe'
        SevenZip   = 'C:\Program Files\7-Zip\7z.exe'
        Rclone     = 'C:\TI\TOOLS\rclone\rclone.exe'
    }

    Database = @{
        Name = 'seven'

        # This file is created only on the server and protected with NTFS ACLs.
        # Expected format:
        # [client]
        # user=backup_user
        # password=change-me
        # host=127.0.0.1
        DefaultsExtraFile = 'C:\TI\SCRIPTS\BackupSeven\Secrets\mysql-backup.cnf'

        # Site-specific mysqldump switches may be added here.
        ExtraArguments = @()
    }

    Fiscal = @{
        SourcePath = 'C:\Seven Sistemas\Fiscal'
    }

    Storage = @{
        ConfigPath = 'C:\TI\SCRIPTS\BackupSeven\Secrets\rclone.conf'
        RemoteRoot = 's3:bucket/backup-seven'
    }

    Archive = @{
        CompressionLevel = 5
    }

    Paths = @{
        RuntimeRoot = 'C:\TI\SCRIPTS\BackupSeven\Runtime'
    }

    Retention = @{
        CompletedDays = 7
        LogDays       = 30
    }
}
