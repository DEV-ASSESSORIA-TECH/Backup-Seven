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
            var sourcePath = args.Last();
            var sourceRoot = sourcePath.TrimEnd('*', Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            if (Directory.Exists(sourceRoot))
            {
                var entries = Directory.GetFiles(sourceRoot, "*", SearchOption.AllDirectories)
                    .Select(path => "ENTRY:" + path.Substring(sourceRoot.Length).TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).Replace('\\', '/') + Environment.NewLine + File.ReadAllText(path));
                File.WriteAllText(archivePath, string.Join(Environment.NewLine, entries));
            }
            else if (File.Exists(sourcePath))
            {
                File.WriteAllText(archivePath, File.ReadAllText(sourcePath));
            }
            else
            {
                File.WriteAllText(archivePath, "fake archive");
            }
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

            var failMatch = Environment.GetEnvironmentVariable("BACKUPSEVEN_FAKE_RCLONE_FAIL_MATCH");
            if (!string.IsNullOrWhiteSpace(failMatch) && args.Any(argument => argument.IndexOf(failMatch, StringComparison.OrdinalIgnoreCase) >= 0))
            {
                return 1;
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

        var executableName = Path.GetFileNameWithoutExtension(Environment.GetCommandLineArgs()[0]);
        if (string.Equals(executableName, "mysql", StringComparison.OrdinalIgnoreCase))
        {
            var rows = Environment.GetEnvironmentVariable("BACKUPSEVEN_FAKE_MYSQL_OBJECTS");
            if (string.IsNullOrWhiteSpace(rows))
            {
                rows = "clientes\tBASE TABLE;produtos\tBASE TABLE;vw_vendas\tVIEW";
            }
            foreach (var row in rows.Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries))
            {
                Console.WriteLine(row);
            }
            return ExitCode("BACKUPSEVEN_FAKE_MYSQL_EXIT");
        }

        var isForceDump = args.Any(argument => argument == "--force");
        var isGeneralDump = args.Any(argument => argument == "--databases");
        var databaseObject = isGeneralDump ? null : args.LastOrDefault();
        var failedObject = Environment.GetEnvironmentVariable("BACKUPSEVEN_FAKE_MYSQLDUMP_FAILED_OBJECT");

        Console.WriteLine("-- BackupSeven fake database dump");
        Console.WriteLine("CREATE DATABASE `seven`;");
        if (!string.IsNullOrWhiteSpace(databaseObject))
        {
            Console.WriteLine("-- Object: " + databaseObject);
        }

        if (!string.IsNullOrWhiteSpace(failedObject) && string.Equals(databaseObject, failedObject, StringComparison.OrdinalIgnoreCase))
        {
            Console.Error.WriteLine("Table '.\\seven\\" + databaseObject + "' is marked as crashed and should be repaired (145)");
            return 2;
        }
        if (isForceDump)
        {
            return ExitCode("BACKUPSEVEN_FAKE_MYSQLDUMP_FORCE_EXIT");
        }
        if (!isGeneralDump)
        {
            return 0;
        }
        var normalExit = Environment.GetEnvironmentVariable("BACKUPSEVEN_FAKE_MYSQLDUMP_NORMAL_EXIT");
        return string.IsNullOrWhiteSpace(normalExit)
            ? ExitCode("BACKUPSEVEN_FAKE_MYSQLDUMP_EXIT")
            : ExitCode("BACKUPSEVEN_FAKE_MYSQLDUMP_NORMAL_EXIT");
    }
}
