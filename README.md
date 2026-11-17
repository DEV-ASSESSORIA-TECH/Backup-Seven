# DBBackup v1 — development branch

Windows / PowerShell 7 database backups with isolated instances, shared scripts,
MySQL 5 and SQL Anywhere 17 providers, optional independent directory jobs,
7z compression, mandatory age encryption and rclone/S3 publication.

**This branch implements steps 1–6 only. It is not a production release.**
Recovery tooling and real restoration tests are intentionally deferred for the
next design discussion. Monitoring integration, process limits and production
packaging remain later steps. VERSION stays at the last released 0.6.0; it does
not identify this development snapshot as a 1.0.0 release.

- [Contracts](contracts/v1.md): configuration, providers, artifacts and scheduling.
- [Architecture](ARCHITECTURE.md): shared code and instance isolation.
- [Runbook](RUNBOOK.md): setup and development operations.
- [Implementation ledger](IMPLEMENTATION.md): commit boundaries and remaining work.

Run `./scripts/verify.ps1` with Pester 5.7.1 and PSScriptAnalyzer 1.25.0.
Tests simulate native tools and scheduler operations; they do not establish
real-world encryption/decryption interoperability or database restorability.
No production databases, scheduled tasks, credentials or legacy installations
are changed by the test suite. Test files are temporary and ACL writes are mocked.

The old application-specific entry points and configuration have been removed.
Install v1 separately when qualified; no automatic migration of old pending or
completed artifacts is provided. Packaging and release commands fail explicitly
until the later release work, preventing accidental distribution of a partial v1.
