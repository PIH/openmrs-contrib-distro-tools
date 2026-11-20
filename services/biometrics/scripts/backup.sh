#!/bin/bash
# biometrics' backup, run by the backups service (its with-backups.yaml mounts it): the fingerprint
# templates' SQLite database, biometrics-data's biometrics.db, as SQL (sqlite3 .dump, one read
# transaction, so consistent while the server writes), streamed into biometrics.sql.7z, never on disk
# unencrypted. The rest of the volume is the server's working directory, which it recreates. Needs
# BACKUP_RUN_DIR and ARCHIVE_PASSWORD. As openmrs-db's, the 7z command line holds the password while
# it runs (docs/backups.md). A server that has never started has no database: nothing is written,
# and the run reports biometrics as not backed up.
set -euo pipefail
: "${BACKUP_RUN_DIR:?}" "${ARCHIVE_PASSWORD:?}"
DB=/sources/biometrics-data/biometrics.db

if [ ! -f "$DB" ]; then
    echo "biometrics: no $DB yet (the server hasn't created it): nothing to back up" >&2
    exit 0
fi
echo "biometrics: dumping $DB" >&2
# -bail stops at the first error; sqlite3's exit status then fails the pipe (pipefail). As the
# database's owner, so a file SQLite creates beside it (its WAL index) stays the server's.
setpriv --reuid="$(stat -c %u "$DB")" --regid="$(stat -c %g "$DB")" --clear-groups \
    sqlite3 -bail "file:$DB?mode=ro" .dump |
    7z a -si"biometrics.sql" -p"$ARCHIVE_PASSWORD" -mx5 -t7z "$BACKUP_RUN_DIR/biometrics.sql.7z" >/dev/null
