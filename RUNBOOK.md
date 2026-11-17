# DBBackup development runbook — steps 1–6

This is a development snapshot, not the 1.0.0 release. No recovery command or
production migration is delivered yet. The historical 0.x changelog remains as
release history. Do not extract this branch over an existing backup installation.

## Requirements

Windows, PowerShell 7, 7-Zip, age and rclone are external dependencies. MySQL jobs
need compatible mysql/mysqldump 5.x clients. SQL Anywhere jobs need SAP 17 dbbackup,
dbvalid and dbeng17, including their native runtime dependencies. No third-party
binaries or private age identities are bundled.

## Create and configure an instance

Use an elevated PowerShell 7 session and the source folder:

```powershell
.\Setup.ps1 -Provider MySQL -InstanceName MySQL
.\Setup.ps1 -Provider SQLAnywhere -InstanceName SQLAnywhere
```

Setup creates `Instances/<name>/config.psd1` from the selected template, asks for
paths/database/storage values and creates missing credentials. Existing secrets
are never overwritten. The shared batch launchers request elevation and then
ask interactively for provider/instance or an existing configuration path.

Secrets use native plaintext option files protected by NTFS ACLs for SYSTEM and
Administrators. They are not encrypted vaults. Keep server access restricted.
The MySQL file is `[client]` with host, port, user and password. SQL options must
be exactly one line, for example (placeholders must be replaced):

```text
-c "UID='REPLACE_USER';PWD='REPLACE_PASSWORD';HOST='REPLACE_HOST:2638';DBN='REPLACE_DATABASE'"
```

SQL connection values cannot contain double quotes or newlines. Single quotes
inside values are doubled. DSN and startup overrides are rejected. SQLAnywhere
v1 requires one main .db file and at least one .log from the native full backup.
No log rename/truncate flags are used. In-memory copied-backup validation uses
fresh private response files; it is not proof of end-to-end restoration.

`Secrets/rclone.conf` is private and local to the instance. `recipients.txt`
contains one native age PUBLIC recipient per line; comments are allowed. Keep
private decryption keys outside this server and preserve the identities needed
for historical backups after recipient rotation. Changing recipients affects
new artifacts only; retry never re-encrypts an old artifact.

Edit configuration to add independent directory jobs:

```powershell
Directories = @(@{ Id = 'documents'; SourcePath = 'D:\Documents' })
```

Sources cannot overlap the instance or its state. Linked files/directories are
rejected. Copying live directories is not an application-consistent snapshot.
Each schedule task references a job explicitly:

```powershell
Schedule = @{ Tasks = @(
    @{ Name='database-daily'; Job='database'; At='19:00'; Frequency='Daily' }
    @{ Name='documents-weekly'; Job='documents'; At='03:00'; Frequency='Weekly'; Days=@('Saturday') }
) }
```

## Diagnose and apply

```powershell
.\Diagnose.ps1 -ConfigPath .\Instances\MySQL\config.psd1
.\Setup.ps1 -ConfigPath .\Instances\MySQL\config.psd1 -Plan
.\Setup.ps1 -ConfigPath .\Instances\MySQL\config.psd1 -Apply
```

Use `-InstancesRoot` consistently when configurations live outside the default
Instances directory. All configurations under that root are checked for duplicate
identities and overlapping state. Diagnostics are local/read-only; rclone
listremotes reads configuration, not remote data. It does not prove database
permissions or AWS connectivity. Plan is read-only, including ACLs and directories.

Apply protects existing config/secrets, checks local dependencies and creates
private state roots. It displays scheduler changes and requires `SIM` before
registration/deletion. Tasks run as SYSTEM in `\DBBackup\<name>\`, with explicit
absolute config and job arguments. Missing Schedule leaves tasks unmanaged;
empty Tasks removes only tasks owned by that config. Foreign tasks cause a
conflict. Old installations' tasks are never searched for or removed.

## Manual development execution

```powershell
.\Backup.ps1 -ConfigPath .\Instances\MySQL\config.psd1 -Job database
.\Backup.ps1 -ConfigPath .\Instances\SQLAnywhere\config.psd1 -All
```

Run only against an explicitly selected test environment until qualification.
One instance has one lock; other instances can execute simultaneously. Runtime
and Completed must be on the same volume for atomic state transitions. Pending
bundles survive publication failures and bypass age retention. Completed bundles
are deleted with their metadata after CompletedDays. LocalStatus can be degraded
or failed even when transport is confirmed. Logs are sanitized and uploaded as
operational text; backup payloads always use .7z.age.

Remote comparison uses rclone check's best common hash, or size if no compatible
hash is available. It is not a download/decryption or restoration exercise.

Work contains unencrypted material during production. Normal completion cleans
that run's work; an interrupted process can leave private temporary files. Inspect
stale Work/Staging only while the instance is stopped. Never delete Pending to
free space. Secure erasure is not promised. Process timeouts, automated space
checks, metrics publication and recovery procedures are pending later steps.

Exit codes: 0 success; 1 operational failure; 2 invalid config/dependency; 3 busy
lock; 4 maintenance failure; 5 complete degraded MySQL fallback published.

## Development verification and qualification

`../scripts/verify.ps1` runs parsing, static analysis and Pester with simulated
external tools. Scheduler/ACL mutations are mocked. This is not a restoration
exercise and does not validate native age/SAP interoperability. Packaging and
release workflows intentionally stop until the separately scoped release work.
Real restore tests and their design will be agreed next; no production migration,
legacy task disablement, release or tag is performed by this implementation.
