# Utilities (openmrs-utils)

Standalone scripts in `utils/` for backing up, restoring and checking MySQL databases and OpenMRS data
directories. They don't need an `openmrs-docker` instance: they work as well against a legacy server
installed directly on a host. Each runs its tools in containers, so the host needs only Docker.

Run one as `openmrs-utils <name> [options]` (a passthrough to `utils/<name>.sh`), or by its full path.
`openmrs-utils <name>` with no options prints its usage, and `openmrs-utils` alone lists them all.

## Conventions

- Values are `--name=value` options. Secrets are environment variables, and reach the tools in
  containers by name, as `MYSQL_PWD` or on stdin, so they're on no command line (the host's `ps`
  shows commands inside containers too). The one exception: `backup-mysqldump --output=<name>.7z`
  streams the dump into 7z on stdin, so `ARCHIVE_PASSWORD` is on 7z's command line inside its
  container while the dump runs.
- The utilities that connect to a MySQL/MariaDB server take it as `--container=<name>` (run inside
  that container) or `--host=<host> [--port=3306]` (over TCP, e.g. `--host=127.0.0.1` for a MySQL
  installed on the host), and log in as `--user` (root by default) with the password in
  `MYSQL_PASSWORD`, refusing to run without it. (`fingerprint` and `backup-percona` used to take
  `MYSQL_ROOT_PASSWORD`, which still works for now, with a warning.) They work with MariaDB 11+,
  whose images have only the `mariadb` tools.
- `.7z` outputs are encrypted with `ARCHIVE_PASSWORD` (required for one), PIH's backup convention.
- Progress and errors go to stderr, so stdout carries only a result a caller may capture (e.g.
  `extract-archive`'s path).
- A backup refuses an output that already exists, and removes what it started writing if it fails,
  saying so. A failing utility always ends with an `error:` line, even when the tool that failed
  (e.g. 7z) only printed a warning.
  Those that write a lot check the free disk space first, as `initialize` does
  ([Disk space](restore.md#disk-space)); `SKIP_DISK_SPACE_CHECK=true` goes ahead anyway.
- Writing a new one: the helpers they share, and these conventions, are in `utils/lib/common.sh`.

## The utilities

| Utility | What it does |
|---|---|
| `backup-mysqldump` | Dumps a database, with its routines and triggers, to `.sql`, `.gz` or `.7z` (streamed in, so never on disk unencrypted), usable as `RESTORE_MYSQL_DUMP_PATH`. `--strip-definers` removes `DEFINER=` clauses as it dumps |
| `backup-percona` | Takes a prepared physical (XtraBackup) backup of a running server's data directory: a directory, or a `.7z` in the legacy nightly `percona.7z` layout, for `RESTORE_MYSQL_PERCONA_PATH` and the DW refresh. `--databases` limits it (the `mysql` system database is always included) |
| `backup-openmrs-data-directory` | Archives an OpenMRS data directory to `.tar.gz` or `.7z`, holding one folder named after the archive, usable as `RESTORE_OPENMRS_DATA_PATH`. `--exclude-distribution-artifacts` leaves out what the image supplies on every start (the contents of `modules/`, `owa/`, `configuration/` and `frontend/`, and `.openmrs-lib-cache`). Refuses while a container uses the directory, unless `--allow-running`. Refuses a directory holding symbolic links (outside what `--exclude-distribution-artifacts` leaves out), listing each with its target: delete the ones not needed, or replace them with what they point to |
| `extract-archive` | Extracts a `.7z`, `.zip`, `.tar.gz`, `.tgz` or `.tar`, and prints the path of its single top-level entry (or of the directory, for an archive with several) |
| `convert-percona-backup` | Turns a prepared XtraBackup directory into a MySQL data directory (`--copy-back`), usable as `RESTORE_MYSQL_DATA_PATH` |
| `strip-mysqldump-definers` | Copies a dump without its `DEFINER=` clauses, so its routines, triggers and views work on a server without the source's accounts |
| `fingerprint` | Writes a sorted summary of a server's databases (and optionally a data directory) to `diff` before and after a restore: server settings, row counts, routines/triggers/views, the latest ids and dates, accounts, files per folder. No row contents or secrets. `--db-volume` reads a stopped server's data directory ([Checking a restore](restore.md#checking-a-restore)) |
| `reset-mysql-accounts` | Sets a stopped data directory's root and application passwords (`MYSQL_ROOT_PASSWORD`, `MYSQL_PASSWORD`) without knowing the current ones; `initialize` runs it after a physical restore |
| `purge-binlogs` | Has a server delete its binary logs except the current one; run it before turning binary logging off |
| `runtime-properties` | Sets aside, or sets keys in, a data directory's `openmrs-runtime.properties` (values on stdin) |
| `clear-configuration-checksums` | Removes openmrs-module-initializer's `configuration_checksums`, so the next start reprocesses all configuration |
| `wait-for-healthy` | Waits until a container's healthcheck reports healthy, failing at once if it stops |
