#!/bin/bash
# Usage: openmrs-docker <name> openmrs-db backup-percona <output-dir>
#
# Takes a physical (xtrabackup) backup of this instance's running openmrs-db into a local
# directory, already prepared (--apply-log) so it's usable directly as input to a later
# restore-percona (on this or another instance). Sourced into bin/openmrs-docker, not run
# standalone: relies on COMPOSE_FILES, NAME, and SERVICE_NAME/OPENMRS_DB_ROOT_PASSWORD (from the
# instance's env file) already being in scope.
set -euo pipefail

OUTPUT_DIR="${1:-}"
[ -z "$OUTPUT_DIR" ] && { echo "usage: $0 $NAME openmrs-db backup-percona <output-dir>" >&2; exit 1; }

DB_CONTAINER=$(docker compose "${COMPOSE_FILES[@]}" ps -q openmrs-db)
[ -z "$DB_CONTAINER" ] && { echo "error: openmrs-db is not running -- start the instance first ('$0 $NAME start')." >&2; exit 1; }

case "$OUTPUT_DIR" in
    /*) ;;
    *) OUTPUT_DIR="$(pwd)/$OUTPUT_DIR" ;;
esac
[ -e "$OUTPUT_DIR" ] && { echo "error: $OUTPUT_DIR already exists" >&2; exit 1; }
mkdir -p "$OUTPUT_DIR"

echo "Backing up ${SERVICE_NAME}'s openmrs-db (physical/xtrabackup) to $OUTPUT_DIR..."
# Shares openmrs-db's network namespace so it can reach it at 127.0.0.1, and mounts its actual
# data directory read-only -- innobackupex needs real filesystem access to the datadir it's
# backing up, not just a network connection to the running mysqld.
docker run --rm --network "container:$DB_CONTAINER" \
    -v "${SERVICE_NAME}_db-data:/var/lib/mysql:ro" \
    -v "$OUTPUT_DIR:/backup" \
    partnersinhealth/percona-0.1-4 \
    innobackupex --user=root --password="${OPENMRS_DB_ROOT_PASSWORD:-openmrs}" --host=127.0.0.1 /backup

# innobackupex writes into a timestamped subdirectory of the given target, owned by the
# container's root -- move its contents up one level (in a container, so this works regardless
# of host/container UID mismatches) so the result is directly usable as restore-percona's <path>.
BACKUP_SUBDIR_NAME=$(docker run --rm -v "$OUTPUT_DIR:/backup" alpine \
    sh -c 'find /backup -mindepth 1 -maxdepth 1 -type d | head -1 | xargs -r basename')
if [ -n "$BACKUP_SUBDIR_NAME" ]; then
    docker run --rm -v "$OUTPUT_DIR:/backup" alpine \
        sh -c "mv \"/backup/$BACKUP_SUBDIR_NAME\"/* /backup/ && rmdir \"/backup/$BACKUP_SUBDIR_NAME\""
fi

echo "Preparing backup (applying transaction log)..."
docker run --rm -v "$OUTPUT_DIR:/backup" partnersinhealth/percona-0.1-4 innobackupex --apply-log /backup

echo "Backed up ${SERVICE_NAME}'s openmrs-db to $OUTPUT_DIR (ready for restore-percona)."
