#!/bin/bash
# biometrics' backup, run by the backups service (its with-backups.yaml mounts it): the fingerprint
# templates' SQLite database, biometrics-data's biometrics.db, copied with SQLite's online backup into
# biometrics.db.7z. The copy is the whole database as it was at one moment (its user_version, journal
# mode and all), taken while the server runs: it waits for a writer's lock to clear (up to
# BIOMETRICS_BACKUP_LOCK_TIMEOUT_MS, default 60000) and holds a read lock only while it copies, which
# is a local file copy. The rest of the volume is the server's working directory, which it recreates.
# Needs BACKUP_RUN_DIR and ARCHIVE_PASSWORD.
#
# The copy goes to .backup-staging in biometrics-data, beside the database (no more exposed than the
# database itself), until it's in the archive, whose password goes on 7z's stdin; it's deleted after,
# and whatever an earlier failed run left there is deleted first. SQLite runs as the database's
# owner, so the files it creates (the copy, a WAL index) stay the server's. A server that has never
# started has no database: nothing is written, and the run reports biometrics as not backed up.
set -euo pipefail
: "${BACKUP_RUN_DIR:?}" "${ARCHIVE_PASSWORD:?}"
DATA=/sources/biometrics-data
DB="$DATA/biometrics.db"
STAGING="$DATA/.backup-staging"

if [ ! -f "$DB" ]; then
    echo "biometrics: no $DB yet (the server hasn't created it): nothing to back up" >&2
    exit 0
fi
as_owner() { setpriv --reuid="$(stat -c %u "$DB")" --regid="$(stat -c %g "$DB")" --clear-groups "$@"; }
cleanup() { rm -rf "$STAGING"; }
cleanup
trap cleanup EXIT
as_owner mkdir "$STAGING"

echo "biometrics: copying $DB" >&2
# -bail: a copy that fails (e.g. a lock held past the timeout) exits non-zero.
as_owner sqlite3 -bail -cmd ".timeout ${BIOMETRICS_BACKUP_LOCK_TIMEOUT_MS:-60000}" \
    "file:$DB?mode=ro" ".backup '$STAGING/biometrics.db'"
check=$(as_owner sqlite3 -bail "$STAGING/biometrics.db" "PRAGMA quick_check")
if [ "$check" != ok ]; then
    echo "error: biometrics: the copy of $DB fails SQLite's check: $check" >&2
    exit 1
fi
cd "$STAGING"
printf '%s\n' "$ARCHIVE_PASSWORD" | 7z a -p -mx5 -mmt2 -t7z "$BACKUP_RUN_DIR/biometrics.db.7z" biometrics.db >/dev/null
