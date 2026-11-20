#!/bin/bash
# openhim's backup, run by the backups service (its with-backups.yaml mounts it): OpenHIM's MongoDB
# database, openhim, as a mongodump archive streamed into openhim.archive.7z, never on disk
# unencrypted. That's the transaction log, audit events and metrics, and the users, channels and
# clients as they are (each mediator provisions its own on start anyway). Needs BACKUP_RUN_DIR and
# ARCHIVE_PASSWORD. As openmrs-db's, the 7z command line holds the password while it runs
# (docs/backups.md). mongo-db takes no login: only the instance's network reaches it.
set -euo pipefail
: "${BACKUP_RUN_DIR:?}" "${ARCHIVE_PASSWORD:?}"

echo "openhim: dumping the openhim database" >&2
# --quiet: mongodump's progress lines would fill backup.log; errors still go to stderr.
mongodump --quiet --host mongo-db --db openhim --archive |
    7z a -si"openhim.archive" -p"$ARCHIVE_PASSWORD" -mx5 -t7z "$BACKUP_RUN_DIR/openhim.archive.7z" >/dev/null
