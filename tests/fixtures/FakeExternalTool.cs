using System;
using System.IO;
using System.Linq;

internal static class FakeExternalTool
{
    private static int ExitCode(string variableName)
    {
        var value = Environment.GetEnvironmentVariable(variableName);
        int exitCode;
        return int.TryParse(value, out exitCode) ? exitCode : 0;
    }

    public static int Main(string[] args)
    {
        var invocationLog = Environment.GetEnvironmentVariable("BACKUPSEVEN_FAKE_INVOCATION_LOG");
        if (!string.IsNullOrWhiteSpace(invocationLog))
        {
            File.AppendAllText(invocationLog, string.Join("|", args) + Environment.NewLine);
        }

        if (args.Length > 0 && args[0] == "a")
        {
            var archivePath = args.Skip(1).First(argument => !argument.StartsWith("-"));
            File.WriteAllText(archivePath, "fake archive");
            return ExitCode("BACKUPSEVEN_FAKE_7ZIP_CREATE_EXIT");
        }

        if (args.Length > 0 && args[0] == "t")
        {
            return ExitCode("BACKUPSEVEN_FAKE_7ZIP_TEST_EXIT");
        }

        if (args.Length > 0 && args[0] == "listremotes")
        {
            Console.WriteLine("s3:");
            return ExitCode("BACKUPSEVEN_FAKE_RCLONE_LIST_EXIT");
        }

        if (args.Length > 0 && args[0] == "copyto")
        {
            if (args.Length > 1 && args[1].EndsWith(".log", StringComparison.OrdinalIgnoreCase))
            {
                return ExitCode("BACKUPSEVEN_FAKE_RCLONE_LOG_COPY_EXIT");
            }

            return ExitCode("BACKUPSEVEN_FAKE_RCLONE_COPY_EXIT");
        }

        if (args.Length > 0 && args[0] == "check")
        {
            if (args.Any(argument => argument.EndsWith(".log", StringComparison.OrdinalIgnoreCase)))
            {
                return ExitCode("BACKUPSEVEN_FAKE_RCLONE_LOG_CHECK_EXIT");
            }

            return ExitCode("BACKUPSEVEN_FAKE_RCLONE_CHECK_EXIT");
        }

        Console.WriteLine("-- BackupSeven fake database dump");
        Console.WriteLine("CREATE DATABASE `seven`;");
        return ExitCode("BACKUPSEVEN_FAKE_MYSQLDUMP_EXIT");
    }
}
