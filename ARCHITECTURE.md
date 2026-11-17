# DBBackup architecture

The public entry point selects an explicit config and one job or all jobs.
Configuration paths resolve against the instance directory. Shared PowerShell
modules contain no instance credentials or mutable per-instance global state.

The core validates configuration and selected dependencies, acquires the
instance lock, retries selected pending jobs, produces each job independently,
packages/encrypts its results, publishes them and applies local retention. A job
failure does not stop the other selected jobs. A pending retry failure remains
an execution failure even when a new package succeeds.

Providers produce typed result objects without uploading. MySQL owns normal,
forced and granular dumps. SQL Anywhere owns native database/log backup and
in-memory validation of the local copy. Directory stages a live file copy;
it provides no snapshot or cross-file consistency guarantee.

Each result package gets its own manifest, tested 7z and age-encrypted payload.
Promotion of payload plus state into Pending uses a same-volume directory move.
Pending bundles carry the immutable destination and encrypted hash. Completed
records confirmed transport, while LocalStatus preserves SUCCESS/DEGRADED/FAILED.
Runtime and Completed must share a volume; promotion to Completed is also an
atomic directory move, so payload and state cannot split during a partial copy.

Setup creates isolated config/Secrets and reconciles tasks scoped by instance
and canonical config-path ownership. Local diagnostics do not test remote SQL
permissions, remote bucket access or recoverability. Scheduled tasks run as
SYSTEM; setup/backup runs require sufficient NTFS privileges.

Do not share a live code directory across independently upgraded releases:
changing shared code affects the next run of all instances using that directory.
Updates should occur with all instance jobs stopped, using a separate qualified
release directory and deliberate task reapplication. Per-instance logs, secrets
and runtime are never part of a distribution package.

Detailed schemas and invariants are in contracts/v1.md. The generic metric
formatter is retained for later integration, but this snapshot does not publish
metrics. Native process timeouts and space checks are also later integration
work; this snapshot must not be installed unattended in production.
