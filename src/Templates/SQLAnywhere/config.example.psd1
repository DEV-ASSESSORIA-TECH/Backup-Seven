@{
    SchemaVersion = 1
    InstanceName = 'SQLAnywhere'
    Provider = 'SQLAnywhere'
    Tools = @{
        DbBackup = 'C:\Program Files\SQL Anywhere 17\Bin64\dbbackup.exe'
        DbValid = 'C:\Program Files\SQL Anywhere 17\Bin64\dbvalid.exe'
        DbEngine = 'C:\Program Files\SQL Anywhere 17\Bin64\dbeng17.exe'
        SevenZip = 'C:\Program Files\7-Zip\7z.exe'
        Age = 'C:\Program Files\age\age.exe'
        Rclone = 'C:\Program Files\rclone\rclone.exe'
    }
    Database = @{ Name = 'REPLACE_DATABASE'; ConnectionOptionsFile = 'Secrets/sqlanywhere.options' }
    Directories = @()
    Storage = @{ ConfigPath = 'Secrets/rclone.conf'; RemoteRoot = 's3:REPLACE_BUCKET' }
    Encryption = @{ RecipientsFile = 'Secrets/recipients.txt' }
    Paths = @{ RuntimeRoot = 'Runtime'; CompletedRoot = 'Completed'; LogRoot = 'Logs' }
    Archive = @{ CompressionLevel = 5; CpuLimitPercent = 50 }
    Retention = @{ CompletedDays = 7; LogDays = 30 }
    Schedule = @{ Tasks = @(@{ Name = 'database-daily'; Job = 'database'; At = '19:00'; Frequency = 'Daily'; Enabled = $true }) }
}
