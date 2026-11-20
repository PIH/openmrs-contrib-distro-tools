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
