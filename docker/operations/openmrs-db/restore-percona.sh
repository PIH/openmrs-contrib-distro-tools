#!/bin/bash
# Usage: openmrs-docker <name> openmrs-db restore-percona <path>
#
# Seeds a brand-new instance's openmrs-db via a physical (xtrabackup) restore -- a one-shot
# init container runs `innobackupex --copy-back` into the db-data volume before openmrs-db ever
# starts. Refuses to run if the instance already has data. Sourced into bin/openmrs-docker, not
# run standalone: relies on COMPOSE_FILES, MODES_DIR, NAME, and the extract_if_7z/
# refuse_if_data_volumes_exist/wait_for_openmrs_db_healthy/remove_restore_scratch helpers
# already being in scope.
set -euo pipefail

RESTORE_PATH="${1:-}"
[ -z "$RESTORE_PATH" ] && { echo "usage: $0 $NAME openmrs-db restore-percona <path>" >&2; exit 1; }
[ -e "$RESTORE_PATH" ] || { echo "error: no such file or directory: $RESTORE_PATH" >&2; exit 1; }
case "$RESTORE_PATH" in
    /*) ;;
    *) RESTORE_PATH="$(cd "$(dirname "$RESTORE_PATH")" && pwd)/$(basename "$RESTORE_PATH")" ;;
esac

refuse_if_data_volumes_exist restore-percona

echo "warning: a percona/xtrabackup restore replaces the entire MySQL datadir, including its user credentials -- the instance's OPENMRS_DB_USER/PASSWORD/ROOT_PASSWORD must match the source server's actual credentials, or the post-restore healthcheck will fail even though the restore itself succeeded. The backup's MySQL server version should also match OPENMRS_DB_IMAGE_TAG." >&2

RESOLVED_PATH=$(extract_if_7z "$RESTORE_PATH")
export RESTORE_PERCONA_PATH="$RESOLVED_PATH"
COMPOSE_FILES+=(-f "$MODES_DIR/restore-percona.yaml")
docker compose "${COMPOSE_FILES[@]}" up -d openmrs-db

wait_for_openmrs_db_healthy restored remove_restore_scratch

docker compose "${COMPOSE_FILES[@]}" down
remove_restore_scratch
echo "Restored $NAME's openmrs-db from $RESTORE_PATH. Run '$0 $NAME start' to bring the instance up."
