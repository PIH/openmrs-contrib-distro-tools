#!/bin/bash
# Usage: openmrs-docker <name> openmrs-db restore-percona <path>
#
# Seeds a brand-new instance's openmrs-db via a physical (xtrabackup) restore -- a one-shot
# init container runs `innobackupex --copy-back` into the db-data volume before openmrs-db ever
# starts. <path> may also be a password-protected archive (.7z, .zip, .tar.gz/.tgz/.tar, via
# bin/openmrs-utils extract-archive) wrapping the prepared backup directory. Refuses to run if
# the instance already has data. Sourced into bin/openmrs-docker, not run standalone: relies on
# COMPOSE_FILES, MODES_DIR, TOOL_DIR, NAME, INSTANCE_DIR, and SERVICE_NAME already being in
# scope.
set -euo pipefail

RESTORE_PATH="${1:-}"
[ -z "$RESTORE_PATH" ] && { echo "usage: $0 $NAME openmrs-db restore-percona <path>" >&2; exit 1; }
[ -e "$RESTORE_PATH" ] || { echo "error: no such file or directory: $RESTORE_PATH" >&2; exit 1; }
case "$RESTORE_PATH" in
    /*) ;;
    *) RESTORE_PATH="$(cd "$(dirname "$RESTORE_PATH")" && pwd)/$(basename "$RESTORE_PATH")" ;;
esac

# restore-percona only runs against a brand-new instance with no existing data.
for vol in openmrs-data db-data; do
    if docker volume inspect "${SERVICE_NAME}_${vol}" >/dev/null 2>&1; then
        echo "error: ${SERVICE_NAME}_${vol} already exists -- restore-percona only runs against a brand-new instance with no existing data. Run '$0 $NAME destroy' first if you really want to start over." >&2
        exit 1
    fi
done

echo "warning: a percona/xtrabackup restore replaces the entire MySQL datadir, including its user credentials -- the instance's OPENMRS_DB_USER/PASSWORD/ROOT_PASSWORD must match the source server's actual credentials, or the post-restore healthcheck will fail even though the restore itself succeeded. The backup's MySQL server version should also match OPENMRS_DB_IMAGE_TAG." >&2

SCRATCH="$INSTANCE_DIR/restore-scratch"
rm -rf "$SCRATCH"
RESOLVED_PATH=$(ARCHIVE_PASSWORD="${PETL_BACKUP_PASSWORD:-}" "$TOOL_DIR/bin/openmrs-utils" extract-archive "$RESTORE_PATH" "$SCRATCH")
export RESTORE_PERCONA_PATH="$RESOLVED_PATH"
COMPOSE_FILES+=(-f "$MODES_DIR/restore-percona.yaml")
docker compose "${COMPOSE_FILES[@]}" up -d openmrs-db

remove_restore_scratch() {
    if [ -d "$SCRATCH" ]; then
        if ! rm -rf "$SCRATCH" 2>/dev/null; then
            docker run --rm -v "$INSTANCE_DIR:/target" alpine chown -R "$(id -u):$(id -g)" /target
            rm -rf "$SCRATCH"
        fi
    fi
}

if ! "$TOOL_DIR/bin/openmrs-utils" wait-for-healthy "${SERVICE_NAME}-openmrs-db" 600; then
    docker compose "${COMPOSE_FILES[@]}" down
    remove_restore_scratch
    exit 1
fi

docker compose "${COMPOSE_FILES[@]}" down
remove_restore_scratch
echo "Restored $NAME's openmrs-db from $RESTORE_PATH. Run '$0 $NAME start' to bring the instance up."
