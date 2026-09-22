#!/bin/bash
# General-purpose: takes a physical (xtrabackup) backup of a running MySQL container's data
# volume into a local directory, already prepared (--apply-log) so it's directly usable as input
# to utils/convert-percona-backup.sh. Usage:
#   utils/backup-percona.sh --container=<name> --volume=<db data volume name> --output=<dir>
#
# MYSQL_ROOT_PASSWORD (env var, not a named argument -- a secret, so it never shows up in `ps`
# output) authenticates as root; defaults to "openmrs" if unset.
set -euo pipefail

CONTAINER=
VOLUME=
OUTPUT_DIR=
for arg in "$@"; do
    case "$arg" in
        --container=*) CONTAINER="${arg#*=}" ;;
        --volume=*) VOLUME="${arg#*=}" ;;
        --output=*) OUTPUT_DIR="${arg#*=}" ;;
        *) echo "unknown argument: $arg" >&2; exit 1 ;;
    esac
done
[ -z "$CONTAINER" ] && { echo "usage: $0 --container=<name> --volume=<db data volume name> --output=<dir>" >&2; exit 1; }
[ -z "$VOLUME" ] && { echo "usage: $0 --container=<name> --volume=<db data volume name> --output=<dir>" >&2; exit 1; }
[ -z "$OUTPUT_DIR" ] && { echo "usage: $0 --container=<name> --volume=<db data volume name> --output=<dir>" >&2; exit 1; }

case "$OUTPUT_DIR" in
    /*) ;;
    *) OUTPUT_DIR="$(pwd)/$OUTPUT_DIR" ;;
esac
[ -e "$OUTPUT_DIR" ] && { echo "error: $OUTPUT_DIR already exists" >&2; exit 1; }
mkdir -p "$OUTPUT_DIR"

echo "Backing up $CONTAINER (physical/xtrabackup) to $OUTPUT_DIR..."
# Shares the container's network namespace so it can reach it at 127.0.0.1, and mounts its
# actual data directory read-only -- innobackupex needs real filesystem access to the datadir
# it's backing up, not just a network connection to the running mysqld.
docker run --rm --network "container:$CONTAINER" \
    -v "$VOLUME:/var/lib/mysql:ro" \
    -v "$OUTPUT_DIR:/backup" \
    partnersinhealth/percona-0.1-4 \
    innobackupex --user=root --password="${MYSQL_ROOT_PASSWORD:-openmrs}" --host=127.0.0.1 /backup

# innobackupex writes into a timestamped subdirectory of the given target, owned by the
# container's root -- move its contents up one level (in a container, so this works regardless
# of host/container UID mismatches) so the result is directly usable as convert-percona-backup.sh's
# --backup-dir.
BACKUP_SUBDIR_NAME=$(docker run --rm -v "$OUTPUT_DIR:/backup" alpine \
    sh -c 'find /backup -mindepth 1 -maxdepth 1 -type d | head -1 | xargs -r basename')
if [ -n "$BACKUP_SUBDIR_NAME" ]; then
    docker run --rm -v "$OUTPUT_DIR:/backup" alpine \
        sh -c "mv \"/backup/$BACKUP_SUBDIR_NAME\"/* /backup/ && rmdir \"/backup/$BACKUP_SUBDIR_NAME\""
fi

echo "Preparing backup (applying transaction log)..."
docker run --rm -v "$OUTPUT_DIR:/backup" partnersinhealth/percona-0.1-4 innobackupex --apply-log /backup

echo "Backed up $CONTAINER to $OUTPUT_DIR (ready for utils/convert-percona-backup.sh)."
