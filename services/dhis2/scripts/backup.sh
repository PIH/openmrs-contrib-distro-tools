#!/bin/bash
# dhis2's backup, run by the backups service (its with-backups.yaml mounts it): the DHIS2 home,
# /sources/dhis2 (the dhis2-data volume), into dhis2.7z, holding one directory, dhis2/: files/,
# apps/ and the version marker .dhis2-version. Not dhis.conf, which dhis2-setup writes on every start
# and which holds the database password, nor .dhis.conf.new (left by a setup that failed before
# renaming it, with the password too), nor logs/ (from a restored legacy home). Needs BACKUP_RUN_DIR and ARCHIVE_PASSWORD.
set -euo pipefail
: "${BACKUP_RUN_DIR:?}" "${ARCHIVE_PASSWORD:?}"

echo "dhis2: archiving /sources/dhis2" >&2
cd /sources
# Links are stored as links (-snl); the password on stdin, so it isn't on 7z's command line.
printf '%s\n' "$ARCHIVE_PASSWORD" | 7z a -p -mx5 -mmt2 -t7z -snl "$BACKUP_RUN_DIR/dhis2.7z" dhis2 -x!dhis2/dhis.conf -x!dhis2/.dhis.conf.new -x!dhis2/logs >/dev/null
