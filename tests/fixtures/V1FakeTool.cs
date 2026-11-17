using System;
using System.IO;
using System.Linq;

internal static class FakeExternalTool
{
    private static string RemoteStore()
    {
        return Path.Combine(Path.GetDirectoryName(Path.GetFullPath(Environment.GetCommandLineArgs()[0])), "remote-store");
    }

    private static string StoredObject(string remotePath)
    {
        // Short, fixed-length name: full remote paths exceed MAX_PATH on Windows.
        using (var algorithm = System.Security.Cryptography.SHA256.Create())
        {
            var digest = algorithm.ComputeHash(System.Text.Encoding.UTF8.GetBytes(remotePath));
            return Path.Combine(RemoteStore(), BitConverter.ToString(digest).Replace("-", "").Substring(0, 32).ToLowerInvariant());
        }
    }

    private static int ExitCode(string variableName)
    {
        var value = Environment.GetEnvironmentVariable(variableName);
        int exitCode;
        return int.TryParse(value, out exitCode) ? exitCode : 0;
    }

    public static int Main(string[] args)
    {
        var invocationLog = Environment.GetEnvironmentVariable("DBBACKUP_FAKE_INVOCATION_LOG");
        if (!string.IsNullOrWhiteSpace(invocationLog))
        {
            File.AppendAllText(invocationLog, string.Join("|", args) + Environment.NewLine);
        }

        if (args.Length > 0 && args[0] == "--sleep")
        {
            System.Threading.Thread.Sleep(int.Parse(args[1]));
            return 0;
        }
        if (args.Length > 0 && args[0] == "--spawn-child")
        {
            var si = new System.Diagnostics.ProcessStartInfo(Environment.GetCommandLineArgs()[0], "--sleep 30000");
            si.UseShellExecute = false;
            si.CreateNoWindow = true;
            var child = System.Diagnostics.Process.Start(si);
            File.WriteAllText(args[1], child.Id.ToString());
            System.Threading.Thread.Sleep(30000);
            return 0;
        }

        if (args.Length > 0 && args[0] == "--encrypt")
        {
            var dest = args[Array.IndexOf(args, "--output") + 1];
            File.Copy(args.Last(), dest);
            return ExitCode("DBBACKUP_FAKE_AGE_EXIT");
        }

        if (args.Length > 0 && args[0] == "a")
        {
            // "dir\*" adds the contents; "dir" adds the folder under its own
            // name (as 7-Zip does); adding to an existing archive appends.
            var archivePath = args.Skip(1).First(argument => !argument.StartsWith("-"));
            var sourcePath = args.Last();
            var contentsOnly = sourcePath.EndsWith("*");
            var sourceRoot = sourcePath.TrimEnd('*', Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            string text;
            if (Directory.Exists(sourceRoot))
            {
                var prefix = contentsOnly ? "" : Path.GetFileName(sourceRoot) + "/";
                var entries = Directory.GetFiles(sourceRoot, "*", SearchOption.AllDirectories)
                    .Select(path => "ENTRY:" + prefix + path.Substring(sourceRoot.Length).TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).Replace('\\', '/') + Environment.NewLine + File.ReadAllText(path));
                text = string.Join(Environment.NewLine, entries);
            }
            else if (File.Exists(sourcePath))
            {
                text = "ENTRY:" + Path.GetFileName(sourcePath) + Environment.NewLine + File.ReadAllText(sourcePath);
            }
            else
            {
                text = "fake archive";
            }
            if (File.Exists(archivePath))
            {
                text = File.ReadAllText(archivePath) + Environment.NewLine + text;
            }
            File.WriteAllText(archivePath, text);
            return ExitCode("DBBACKUP_FAKE_7ZIP_CREATE_EXIT");
        }

        if (args.Length > 0 && args[0] == "rn")
        {
            var names = args.Skip(1).Where(argument => !argument.StartsWith("-")).ToArray();
            var renamed = File.ReadAllText(names[0]).Replace("ENTRY:" + names[1] + "/", "ENTRY:" + names[2] + "/");
            File.WriteAllText(names[0], renamed);
            return ExitCode("DBBACKUP_FAKE_7ZIP_RENAME_EXIT");
        }

        if (args.Length > 0 && args[0] == "t")
        {
            return ExitCode("DBBACKUP_FAKE_7ZIP_TEST_EXIT");
        }

        if (args.Length > 0 && args[0] == "listremotes")
        {
            Console.WriteLine("s3:");
            return ExitCode("DBBACKUP_FAKE_RCLONE_LIST_EXIT");
        }

        if (args.Length > 0 && args[0] == "copyto")
        {
            int copyExit;
            var failMatch = Environment.GetEnvironmentVariable("DBBACKUP_FAKE_RCLONE_FAIL_MATCH");
            if (args.Length > 1 && args[1].EndsWith(".log", StringComparison.OrdinalIgnoreCase))
            {
                copyExit = ExitCode("DBBACKUP_FAKE_RCLONE_LOG_COPY_EXIT");
            }
            else if (!string.IsNullOrWhiteSpace(failMatch) && args.Any(argument => argument.IndexOf(failMatch, StringComparison.OrdinalIgnoreCase) >= 0))
            {
                copyExit = 1;
            }
            else
            {
                copyExit = ExitCode("DBBACKUP_FAKE_RCLONE_COPY_EXIT");
            }
            if (copyExit == 0)
            {
                // Simulated bucket: lsjson reports what was really uploaded.
                Directory.CreateDirectory(RemoteStore());
                File.Copy(args[1], StoredObject(args[2]), true);
            }
            return copyExit;
        }

        if (args.Length > 0 && args[0] == "lsjson")
        {
            var include = args[Array.IndexOf(args, "--include") + 1].TrimStart('/');
            var listExit = ExitCode(include.EndsWith(".log", StringComparison.OrdinalIgnoreCase) ? "DBBACKUP_FAKE_RCLONE_LOG_CHECK_EXIT" : "DBBACKUP_FAKE_RCLONE_CHECK_EXIT");
            if (listExit != 0)
            {
                return listExit;
            }
            var stored = StoredObject(args[1] + "/" + include);
            if (!File.Exists(stored))
            {
                Console.WriteLine("[]");
                return 0;
            }
            string md5;
            using (var algorithm = System.Security.Cryptography.MD5.Create())
            using (var stream = File.OpenRead(stored))
            {
                md5 = BitConverter.ToString(algorithm.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
            }
            var forced = Environment.GetEnvironmentVariable("DBBACKUP_FAKE_RCLONE_REMOTE_MD5");
            if (!string.IsNullOrWhiteSpace(forced))
            {
                md5 = forced;
            }
            var hashes = string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("DBBACKUP_FAKE_RCLONE_NO_HASH")) ? ",\"Hashes\":{\"md5\":\"" + md5 + "\"}" : "";
            Console.WriteLine("[{\"Path\":\"" + include + "\",\"Name\":\"" + include + "\",\"Size\":" + new FileInfo(stored).Length + hashes + "}]");
            return 0;
        }

        var executableName = Path.GetFileNameWithoutExtension(Environment.GetCommandLineArgs()[0]);
        if (string.Equals(executableName, "mysql", StringComparison.OrdinalIgnoreCase))
        {
            if (args.Any(argument => argument.IndexOf("information_schema", StringComparison.OrdinalIgnoreCase) >= 0))
            {
                var size = Environment.GetEnvironmentVariable("DBBACKUP_FAKE_MYSQL_SIZE");
                Console.WriteLine(string.IsNullOrWhiteSpace(size) ? "12345" : size);
                return ExitCode("DBBACKUP_FAKE_MYSQL_EXIT");
            }
            var rows = Environment.GetEnvironmentVariable("DBBACKUP_FAKE_MYSQL_OBJECTS");
            if (string.IsNullOrWhiteSpace(rows))
            {
                rows = "clientes\tBASE TABLE;produtos\tBASE TABLE;vw_vendas\tVIEW";
            }
            foreach (var row in rows.Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries))
            {
                Console.WriteLine(row);
            }
            return ExitCode("DBBACKUP_FAKE_MYSQL_EXIT");
        }

        var isForceDump = args.Any(argument => argument == "--force");
        var isGeneralDump = args.Any(argument => argument == "--databases");
        var databaseObject = isGeneralDump ? null : args.LastOrDefault();
        var failedObject = Environment.GetEnvironmentVariable("DBBACKUP_FAKE_MYSQLDUMP_FAILED_OBJECT");

        Console.WriteLine("-- DBBackup fake database dump");
        Console.WriteLine("CREATE DATABASE `testdb`;");
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
            return ExitCode("DBBACKUP_FAKE_MYSQLDUMP_FORCE_EXIT");
        }
        if (!isGeneralDump)
        {
            return 0;
        }
        var normalExit = Environment.GetEnvironmentVariable("DBBACKUP_FAKE_MYSQLDUMP_NORMAL_EXIT");
        return string.IsNullOrWhiteSpace(normalExit)
            ? ExitCode("DBBACKUP_FAKE_MYSQLDUMP_EXIT")
            : ExitCode("DBBACKUP_FAKE_MYSQLDUMP_NORMAL_EXIT");
    }
}
