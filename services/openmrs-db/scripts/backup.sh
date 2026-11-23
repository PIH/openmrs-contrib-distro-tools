#!/bin/bash
# openmrs-db's backup, run by the backups service (its with-backups.yaml mounts it): a consistent
# dump of the openmrs database (as backup-mysqldump makes) streamed into openmrs-db.sql.7z, never on
# disk unencrypted. Needs OPENMRS_DB_ROOT_PASSWORD, BACKUP_RUN_DIR and ARCHIVE_PASSWORD. The 7z
# command line holds the password while it runs, which the host's `ps` shows to every host user
# (docs/backups.md): the data is on stdin, and 7z reads part of it with a password given there too,
# and stores a named pipe as a pipe rather than reading it.
set -euo pipefail
source /opt/backup/in-container/mysqldump-options.sh
: "${OPENMRS_DB_ROOT_PASSWORD:?}" "${BACKUP_RUN_DIR:?}" "${ARCHIVE_PASSWORD:?}"

# TCP: the client's default for a host name.
# --column-statistics=0: Oracle's 8.x mysqldump otherwise reads information_schema.COLUMN_STATISTICS,
# which MariaDB lacks (the dump fails) and MySQL 5.6/5.7 lack (a warning).
export MYSQL_PWD="$OPENMRS_DB_ROOT_PASSWORD"   # not on the command line
echo "openmrs-db: dumping openmrs" >&2
# shellcheck disable=SC2086 # the options are words
mysqldump --protocol=TCP --column-statistics=0 -h openmrs-db -u root $MYSQLDUMP_BACKUP_OPTIONS openmrs |
    7z a -si"openmrs-db.sql" -p"$ARCHIVE_PASSWORD" -mx5 -mmt2 -t7z "$BACKUP_RUN_DIR/openmrs-db.sql.7z" >/dev/null
