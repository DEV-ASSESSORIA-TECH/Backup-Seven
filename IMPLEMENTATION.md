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
