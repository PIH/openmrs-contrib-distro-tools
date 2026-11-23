#!/bin/bash
# sqlserver's backup, run by the backups service (its with-backups.yaml mounts it): each database in
# SQLSERVER_BACKUP_DATABASES (space-separated; empty, the default, backs up nothing and the run
# reports sqlserver as not backed up), as a full COPY_ONLY backup, into sqlserver.7z (one <db>.bak
# each). Needs BACKUP_RUN_DIR, ARCHIVE_PASSWORD and SQLCMDPASSWORD (sa's, which sqlcmd reads).
#
# SQL Server writes a backup only to its own disk: each .bak goes to .backup-staging in
# sqlserver-data (mounted here at /sources/sqlserver-data, and in the server at /var/opt/mssql),
# unencrypted beside the database's own files, until it's in the archive; it's deleted after, and
# whatever an earlier failed run left there is deleted first. The archive's password goes on 7z's
# stdin.
set -euo pipefail
: "${BACKUP_RUN_DIR:?}" "${ARCHIVE_PASSWORD:?}" "${SQLCMDPASSWORD:?}"
read -r -a databases <<< "${SQLSERVER_BACKUP_DATABASES:-}"
if [ ${#databases[@]} -eq 0 ]; then
    echo "sqlserver: SQLSERVER_BACKUP_DATABASES is empty: no database chosen to back up" >&2
    exit 0
fi
for db in "${databases[@]}"; do
    if [[ ! "$db" =~ ^[A-Za-z0-9_]+$ ]]; then
        echo "error: SQLSERVER_BACKUP_DATABASES: '$db' isn't a database name (letters, digits and _)" >&2
        exit 1
    fi
done

# Room for the .bak files and, beside them, their archive (the volumes share Docker's disk): twice the
# space the chosen databases' data uses, plus 10%. The run's own check (backup.sh) counts only the
# newest run's archives, not this uncompressed staging, so a large database could otherwise fill the
# disk under the running servers.
used_kb=0
for db in "${databases[@]}"; do
    # The pages its tables and indexes use (by name, not USE: go-sqlcmd prints USE's message). A failed
    # query (no such database) leaves kb empty, for the message below rather than set -e's bare exit.
    kb=$(sqlcmd -S sqlserver -U sa -C -b -h -1 -W -Q "SET NOCOUNT ON;
        SELECT SUM(CAST(used_pages AS bigint)) * 8 FROM [$db].sys.allocation_units") || kb=
    if [[ ! "$kb" =~ ^[0-9]+$ ]]; then
        echo "error: sqlserver: couldn't read the size of $db (does it exist?)" >&2
        exit 1
    fi
    used_kb=$((used_kb + kb))
done
needed_kb=$((used_kb * 2 + used_kb / 5))
free_kb=$(df -Pk /sources/sqlserver-data | awk 'NR == 2 { print $4 }')
if [ "$free_kb" -lt "$needed_kb" ]; then
    echo "error: sqlserver: not enough free space for the backup: the chosen databases' data is ${used_kb} KB, which needs ${needed_kb} KB free (the .bak files and their archive), and ${free_kb} KB is free" >&2
    exit 1
fi

LOCAL=/sources/sqlserver-data/.backup-staging   # here
SERVER=/var/opt/mssql/.backup-staging           # the same directory, as the server sees it
cleanup() { rm -rf "$LOCAL"; }
cleanup
trap cleanup EXIT
mkdir "$LOCAL"
# The server runs as mssql (uid 10001 in Microsoft's image), which owns its data directory (the
# volume's top is root's): it must be able to write here.
chown "$(stat -c %u:%g /sources/sqlserver-data/data)" "$LOCAL"

for db in "${databases[@]}"; do
    echo "sqlserver: backing up $db" >&2
    # -b: exit non-zero on a SQL error. -C: the server's certificate is self-signed.
    sqlcmd -S sqlserver -U sa -C -b -Q "BACKUP DATABASE [$db] TO DISK = N'$SERVER/$db.bak' WITH COPY_ONLY, INIT, CHECKSUM" >&2
done
cd "$LOCAL"
printf '%s\n' "$ARCHIVE_PASSWORD" | 7z a -p -mx5 -t7z "$BACKUP_RUN_DIR/sqlserver.7z" ./*.bak >/dev/null
