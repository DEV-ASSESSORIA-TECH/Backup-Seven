# v1 implementation ledger

Branch: release/1.0.0. Breaking replacement of the 0.x interfaces.

1. docs: define DBBackup v1 scope and contracts
2. refactor!: introduce instance-based DBBackup core
3. refactor!: extract MySQL and directory providers
4. feat: add mandatory age encryption and artifact state
5. feat: add SQL Anywhere 17 full backups
6. feat!: unify setup secrets and task scheduling

Stop after step 6 for recovery-design discussion. Steps 7–11 (recovery tooling,
metrics/limits, packaging, final operations documentation, VERSION/release) are
not included in this implementation request. Each functional commit includes
targeted tests. Real database recovery is neither performed nor claimed here.

## Delivered through step 6

- Instance schema, paths, isolation, lock and generic entry point.
- MySQL full/degraded and independent directory jobs.
- Mandatory age after tested 7z; bundle manifest/state, immutable retry and retention.
- Native SQL Anywhere full-backup and copied-file validation provider.
- Shared interactive setup, secrets protection/preservation, local diagnosis,
  read-only scheduler plans and ownership-scoped task reconciliation.
- Generic services retained under Core; obsolete entry points/tests retired.
- CI validates development source; packaging/release deliberately blocked until
  their separately scoped implementation and real recovery qualification.

Tests use temporary fixtures, simulated native tools and mocked ACL/scheduler
mutations. No production connection, actual recovery or installed task change
was used for implementation verification. Native age and SQL Anywhere response-
file interoperability still requires the agreed real-environment qualification.

Verification on 2026-11-17: 60 Pester tests passed, zero failures/skips;
30 PowerShell source/configuration files parsed; PSScriptAnalyzer reported no
warnings/errors; git diff --check passed. The same-volume transition check and
generic directory execution are covered by the final complete test run.
