#!/bin/bash
# Usage: openmrs-docker <name> openmrs-db restore-dump <path>
#
# Seeds a brand-new instance's openmrs-db from a local SQL dump (optionally a
# password-protected archive containing one -- .7z, .zip, .tar.gz/.tgz/.tar, via bin/
# openmrs-utils extract-archive), bind-mounted into MySQL's own first-boot import mechanism.
# Refuses to run if the instance already has data -- run `destroy` first if you really want to
# start over. Sourced into bin/openmrs-docker, not run standalone: relies on COMPOSE_FILES,
# MODES_DIR, TOOL_DIR, NAME, INSTANCE_DIR, and SERVICE_NAME already being in scope.
set -euo pipefail

RESTORE_PATH="${1:-}"
[ -z "$RESTORE_PATH" ] && { echo "usage: $0 $NAME openmrs-db restore-dump <path>" >&2; exit 1; }
# An absent path is silently auto-created as an empty *directory* by Docker's bind mount, which
# MySQL's entrypoint then fails to read as a dump file -- burning the full health-poll timeout
# before producing an unhelpful error.
[ -e "$RESTORE_PATH" ] || { echo "error: no such file or directory: $RESTORE_PATH" >&2; exit 1; }
# Compose's short volume syntax reads a source that doesn't start with . / or ~ as a *named
# volume*, so a relative path fails with a confusing "refers to undefined volume" error.
# Normalize to absolute here (portably -- no realpath, absent on macOS before 12.3).
case "$RESTORE_PATH" in
    /*) ;;
    *) RESTORE_PATH="$(cd "$(dirname "$RESTORE_PATH")" && pwd)/$(basename "$RESTORE_PATH")" ;;
esac

# restore-dump only runs against a brand-new instance with no existing data.
for vol in openmrs-data db-data; do
    if docker volume inspect "${SERVICE_NAME}_${vol}" >/dev/null 2>&1; then
        echo "error: ${SERVICE_NAME}_${vol} already exists -- restore-dump only runs against a brand-new instance with no existing data. Run '$0 $NAME destroy' first if you really want to start over." >&2
        exit 1
    fi
done

SCRATCH="$INSTANCE_DIR/restore-scratch"
rm -rf "$SCRATCH"
RESOLVED_PATH=$(ARCHIVE_PASSWORD="${PETL_BACKUP_PASSWORD:-}" "$TOOL_DIR/bin/openmrs-utils" extract-archive "$RESTORE_PATH" "$SCRATCH")
export RESTORE_DUMP_PATH="$RESOLVED_PATH"
case "$RESOLVED_PATH" in
    *.gz) export RESTORE_DUMP_FILENAME="dump.sql.gz" ;;
    *)    export RESTORE_DUMP_FILENAME="dump.sql" ;;
esac
COMPOSE_FILES+=(-f "$MODES_DIR/restore-dump.yaml")
docker compose "${COMPOSE_FILES[@]}" up -d openmrs-db

# Extracted content (if extract-archive ran) is written by a container running as root, so the
# host-side rm can fail -- same reclaim-ownership fallback destroy uses.
remove_restore_scratch() {
    if [ -d "$SCRATCH" ]; then
        if ! rm -rf "$SCRATCH" 2>/dev/null; then
            docker run --rm -v "$INSTANCE_DIR:/target" alpine chown -R "$(id -u):$(id -g)" /target
            rm -rf "$SCRATCH"
        fi
    fi
}

# A failed attempt is torn down here too (not just on success), so the instance is left in the
# same state either way -- but note this does NOT remove the db-data volume, so a retry still
# requires `destroy` first, exactly like `initialize`.
if ! "$TOOL_DIR/bin/openmrs-utils" wait-for-healthy "${SERVICE_NAME}-openmrs-db" 600; then
    docker compose "${COMPOSE_FILES[@]}" down
    remove_restore_scratch
    exit 1
fi

# Leaves the stack down, the same way `initialize` does -- this is a one-shot data-loading
# operation, and openmrs-db is running against a throwaway overlay (a bind-mounted dump) that
# shouldn't outlive it. This `down` (no -v, so the restored db-data volume survives) also makes
# removing the extraction scratch dir below safe: for an archive-based restore that directory is
# the bind-mount source openmrs-db is still holding open.
docker compose "${COMPOSE_FILES[@]}" down
remove_restore_scratch
echo "Restored $NAME's openmrs-db from $RESTORE_PATH. Run '$0 $NAME start' to bring the instance up."
