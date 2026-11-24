#!/bin/bash
# dhis2-db's backup, run by the backups service (its with-backups.yaml mounts it): a plain-format
# pg_dump of the DHIS2 database streamed into dhis2-db.sql.7z, never on disk unencrypted. It leaves
# out the analytics_* tables' rows (DHIS2 rebuilds them with its analytics job), but not their
# definitions: a view on one (a DHIS2 SQL view) would otherwise fail the restore. And it leaves out
# ownership and privileges, so the dump restores under whatever account the new instance has. Needs
# DHIS2_DB_USER, DHIS2_DB_NAME, DHIS2_DB_PASSWORD, BACKUP_RUN_DIR and ARCHIVE_PASSWORD. The 7z
# command line holds the archive password while it runs, which the host's `ps` shows to every host
# user (docs/backups.md): the data is on stdin, and 7z reads part of it with a password given there too.
#
# The image's pg_dump is 18, newer than the server (DHIS2 runs on 16), and its dump has two things an
# older server or psql rejects: `SET transaction_timeout` (in the header) and the `\restrict` and
# `\unrestrict` lines. The sed drops them, so the dump imports into the PostgreSQL 16 of dhis2-db.
set -euo pipefail
: "${DHIS2_DB_USER:?}" "${DHIS2_DB_NAME:?}" "${DHIS2_DB_PASSWORD:?}" "${BACKUP_RUN_DIR:?}" "${ARCHIVE_PASSWORD:?}"

export PGPASSWORD="$DHIS2_DB_PASSWORD"   # not on the command line
echo "dhis2-db: dumping $DHIS2_DB_NAME" >&2
pg_dump -h dhis2-db -U "$DHIS2_DB_USER" -O -x --exclude-table-data='analytics_*' "$DHIS2_DB_NAME" |
    sed -e '1,40{/^SET transaction_timeout = 0;$/d}' -e '/^\\\(un\)\{0,1\}restrict /d' |
    7z a -si"dhis2-db.sql" -p"$ARCHIVE_PASSWORD" -mx5 -mmt2 -t7z "$BACKUP_RUN_DIR/dhis2-db.sql.7z" >/dev/null
