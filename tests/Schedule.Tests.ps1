Describe 'Schedule module' {
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/Modules/Schedule.psm1') -Force

    function Get-TestTask([object[]] $Tasks) {
        return Get-SevenScheduleTask -Configuration @{ Schedule = @{ Tasks = $Tasks } }
    }
}

Context 'Normalization' {
    It 'returns no task without the Schedule section' {
        @(Get-SevenScheduleTask -Configuration @{}).Count | Should -Be 0
    }

    It 'expands a plain time into a daily Full task with a derived name' {
        $task = @(Get-TestTask @('19:00'))[0]

        $task.Name | Should -Be 'Full Daily 19h00'
        $task.Mode | Should -Be 'Full'
        $task.Frequency | Should -Be 'Daily'
        $task.At | Should -Be '19:00'
        $task.Enabled | Should -BeTrue
    }

    It 'normalizes case, weekly days and monthly days' {
        $tasks = Get-TestTask @(
            @{ Name = 'Banco'; Mode = 'database'; Frequency = 'weekly'; Days = @('saturday', 'Wednesday'); At = '03:00' }
            @{ Mode = 'Fiscal'; Frequency = 'Monthly'; DaysOfMonth = @(15, 'last', 1); At = '22:00'; Enabled = $false }
        )

        $tasks[0].Mode | Should -Be 'Database'
        $tasks[0].Days | Should -Be @('Wednesday', 'Saturday')
        $tasks[1].DaysOfMonth | Should -Be @('15', 'Last', '1')
        $tasks[1].Enabled | Should -BeFalse
    }

    It 'rejects invalid entries with the item position' {
        { Get-TestTask @(@{ At = '7:00' }) } | Should -Throw '*Tasks`[1`].At*'
        { Get-TestTask @(@{ At = '07:00'; Mode = 'Tudo' }) } | Should -Throw '*Mode*'
        { Get-TestTask @(@{ At = '07:00'; Frequency = 'Weekly' }) } | Should -Throw '*Days is required*'
        { Get-TestTask @(@{ At = '07:00'; Frequency = 'Weekly'; Days = @('Segunda') }) } | Should -Throw '*invalid day*'
        { Get-TestTask @(@{ At = '07:00'; Days = @('Monday') }) } | Should -Throw '*only valid*'
        { Get-TestTask @(@{ At = '07:00'; Frequency = 'Monthly'; DaysOfMonth = @(32) }) } | Should -Throw '*invalid day*'
        { Get-TestTask @(@{ At = '07:00'; Foo = 1 }) } | Should -Throw '*unknown key*'
        { Get-TestTask @('12:00', '12:00') } | Should -Throw '*repeated*'
    }
}

Context 'Expected interval' {
    It 'is 17 hours for daily Full runs at 12:00 and 19:00' {
        $tasks = Get-TestTask @('12:00', '19:00')

        Get-SevenScheduleMaxGap -Tasks $tasks -BackupType Database | Should -Be 17
        Get-SevenScheduleMaxGap -Tasks $tasks -BackupType Fiscal | Should -Be 17
    }

    It 'ignores disabled tasks and tasks of the other type' {
        $tasks = Get-TestTask @(
            @{ Mode = 'Database'; At = '03:00' }
            @{ Mode = 'Fiscal'; Frequency = 'Weekly'; Days = @('Monday'); At = '22:00' }
            @{ Mode = 'Full'; At = '12:00'; Enabled = $false }
        )

        Get-SevenScheduleMaxGap -Tasks $tasks -BackupType Database | Should -Be 24
        Get-SevenScheduleMaxGap -Tasks $tasks -BackupType Fiscal | Should -Be 168
    }

    It 'returns null when no enabled task covers the type' {
        $tasks = Get-TestTask @(@{ Mode = 'Database'; At = '03:00' })

        Get-SevenScheduleMaxGap -Tasks $tasks -BackupType Fiscal | Should -BeNullOrEmpty
    }

    It 'warns about enabled tasks at the same time' {
        $tasks = Get-TestTask @('12:00', @{ Mode = 'Database'; At = '12:00' })

        @(Get-SevenScheduleWarning -Tasks $tasks).Count | Should -Be 1
    }
}

Context 'Next run' {
    It 'returns the first covering run strictly after the given time' {
        $tasks = Get-TestTask @('12:00', '19:00')
        $after = [DateTime]::new(2026, 11, 16, 12, 0, 5)

        Get-SevenScheduleNextRun -Tasks $tasks -BackupType Database -After $after |
            Should -Be ([DateTime]::new(2026, 11, 16, 19, 0, 0))
        Get-SevenScheduleNextRun -Tasks $tasks -BackupType Fiscal -After ([DateTime]::new(2026, 11, 16, 19, 30, 0)) |
            Should -Be ([DateTime]::new(2026, 11, 17, 12, 0, 0))
    }

    It 'follows weekly and monthly calendars and skips other types and disabled tasks' {
        $tasks = Get-TestTask @(
            @{ Mode = 'Database'; Frequency = 'Weekly'; Days = @('Saturday'); At = '03:00' }
            @{ Mode = 'Fiscal'; Frequency = 'Monthly'; DaysOfMonth = @('Last'); At = '22:00' }
            @{ Mode = 'Full'; At = '08:00'; Enabled = $false }
        )
        $after = [DateTime]::new(2026, 11, 16, 10, 0, 0)  # segunda-feira

        Get-SevenScheduleNextRun -Tasks $tasks -BackupType Database -After $after |
            Should -Be ([DateTime]::new(2026, 11, 21, 3, 0, 0))
        Get-SevenScheduleNextRun -Tasks $tasks -BackupType Fiscal -After $after |
            Should -Be ([DateTime]::new(2026, 11, 30, 22, 0, 0))
    }

    It 'returns null when no enabled task covers the type' {
        $tasks = Get-TestTask @(@{ Mode = 'Database'; At = '03:00' })

        Get-SevenScheduleNextRun -Tasks $tasks -BackupType Fiscal -After ([DateTime]::Now) | Should -BeNullOrEmpty
    }
}

Context 'Task definition' {
    It 'builds a SYSTEM task with ExecutionPolicy Bypass and a stable fingerprint' {
        $task = @(Get-TestTask @(@{ Mode = 'Fiscal'; Frequency = 'Monthly'; DaysOfMonth = @(1, 'Last'); At = '22:00' }))[0]
        $definition = Get-SevenTaskDefinition -Task $task -PwshPath 'C:\pwsh.exe' -ScriptPath 'C:\B\Backup-Seven.ps1' -WorkingDirectory 'C:\B'
        $again = Get-SevenTaskDefinition -Task $task -PwshPath 'C:\pwsh.exe' -ScriptPath 'C:\B\Backup-Seven.ps1' -WorkingDirectory 'C:\B'
        [xml] $xml = $definition.Xml
        $ns = [System.Xml.XmlNamespaceManager]::new($xml.NameTable)
        $ns.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')

        $xml.SelectSingleNode('//t:Principal/t:UserId', $ns).InnerText | Should -Be 'S-1-5-18'
        $xml.SelectSingleNode('//t:Exec/t:Arguments', $ns).InnerText |
            Should -Be '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\B\Backup-Seven.ps1" -Mode Fiscal'
        $xml.SelectSingleNode('//t:CalendarTrigger/t:StartBoundary', $ns).InnerText | Should -Be '2026-01-01T22:00:00'
        @($xml.SelectNodes('//t:DaysOfMonth/t:Day', $ns) | ForEach-Object InnerText) | Should -Be @('1', 'Last')
        @($xml.SelectNodes('//t:Months/*', $ns)).Count | Should -Be 12
        $xml.SelectSingleNode('//t:RegistrationInfo/t:SecurityDescriptor', $ns).InnerText | Should -Be (Get-SevenScheduleTaskSecurity)
        Get-SevenTaskDefinitionHash -Description $xml.SelectSingleNode('//t:Description', $ns).InnerText | Should -Be $definition.Hash
        $again.Hash | Should -Be $definition.Hash
    }

    It 'changes the fingerprint when the schedule changes' {
        $first = @(Get-TestTask @('12:00'))[0]
        $second = @(Get-TestTask @(@{ Name = 'Full Daily 12h00'; At = '12:30' }))[0]

        (Get-SevenTaskDefinition -Task $first -PwshPath 'p' -ScriptPath 's' -WorkingDirectory 'w').Hash |
            Should -Not -Be (Get-SevenTaskDefinition -Task $second -PwshPath 'p' -ScriptPath 's' -WorkingDirectory 'w').Hash
    }
}
}
