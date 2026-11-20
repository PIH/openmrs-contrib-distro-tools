#!/bin/bash
# The backups container's entrypoint: runs the backup and upload jobs on their schedules with
# supercronic, which doesn't start a job while its previous run is still going.
#   BACKUP_SCHEDULE, BACKUP_UPLOAD_SCHEDULE   cron expressions, in TZ
set -euo pipefail

: "${BACKUP_SCHEDULE:?BACKUP_SCHEDULE must be set}"
: "${BACKUP_UPLOAD_SCHEDULE:?BACKUP_UPLOAD_SCHEDULE must be set}"
CRONTAB=/tmp/crontab
{
    echo "$BACKUP_SCHEDULE bash /opt/backup/backup.sh"
    echo "$BACKUP_UPLOAD_SCHEDULE bash /opt/backup/upload.sh"
} > "$CRONTAB"
# A bad schedule would otherwise only show as supercronic restarting (restart: unless-stopped).
if ! out=$(supercronic -test "$CRONTAB" 2>&1); then
    printf '%s\n' "$out" >&2
    echo "error: invalid BACKUP_SCHEDULE or BACKUP_UPLOAD_SCHEDULE: '$BACKUP_SCHEDULE', '$BACKUP_UPLOAD_SCHEDULE'" >&2
    exit 1
fi
echo "backup schedule '$BACKUP_SCHEDULE', upload schedule '$BACKUP_UPLOAD_SCHEDULE' (TZ ${TZ:-unset})" >&2
exec supercronic "$CRONTAB"
