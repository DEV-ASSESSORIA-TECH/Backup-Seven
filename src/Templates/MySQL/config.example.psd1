@{
    SchemaVersion = 1
    InstanceName = 'MySQL'
    Provider = 'MySQL'
    Tools = @{
        MySql = 'C:\Program Files\MySQL\MySQL Server 5.5\bin\mysql.exe'
        MySqlDump = 'C:\Program Files\MySQL\MySQL Server 5.5\bin\mysqldump.exe'
        SevenZip = 'C:\Program Files\7-Zip\7z.exe'
        Age = 'C:\Program Files\age\age.exe'
        Rclone = 'C:\Program Files\rclone\rclone.exe'
    }
    Database = @{ Name = 'REPLACE_DATABASE'; DefaultsExtraFile = 'Secrets/mysql.cnf'; ExtraArguments = @('--skip-events') }
    Directories = @()
    Storage = @{ ConfigPath = 'Secrets/rclone.conf'; RemoteRoot = 's3:REPLACE_BUCKET' }
    Encryption = @{ RecipientsFile = 'Secrets/recipients.txt' }
    Paths = @{ RuntimeRoot = 'Runtime'; CompletedRoot = 'Completed'; LogRoot = 'Logs' }
    Archive = @{ CompressionLevel = 5; CpuLimitPercent = 50 }
    Retention = @{ CompletedDays = 7; LogDays = 30 }
    Schedule = @{ Tasks = @(@{ Name = 'database-daily'; Job = 'database'; At = '19:00'; Frequency = 'Daily'; Enabled = $true }) }
}
