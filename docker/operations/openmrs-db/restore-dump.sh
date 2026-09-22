#!/bin/bash
# Usage: openmrs-docker <name> openmrs-db restore-dump <path>
#
# Seeds a brand-new instance's openmrs-db from a local SQL dump (optionally a
# password-protected .7z archive containing one), bind-mounted into MySQL's own first-boot
# import mechanism. Refuses to run if the instance already has data -- run `destroy` first if
# you really want to start over. Sourced into bin/openmrs-docker, not run standalone: relies on
# COMPOSE_FILES, MODES_DIR, NAME, and the extract_if_7z/refuse_if_data_volumes_exist/
# wait_for_openmrs_db_healthy/remove_restore_scratch helpers already being in scope.
set -euo pipefail

RESTORE_PATH="${1:-}"
[ -z "$RESTORE_PATH" ] && { echo "usage: $0 $NAME openmrs-db restore-dump <path>" >&2; exit 1; }
# An absent path is silently auto-created as an empty *directory* by Docker's bind mount, which
# MySQL's entrypoint then fails to read as a dump file -- burning the full health-poll timeout
# before producing an unhelpful error.
[ -e "$RESTORE_PATH" ] || { echo "error: no such file or directory: $RESTORE_PATH" >&2; exit 1; }
# Compose's short volume syntax reads a source that doesn't start with . / or ~ as a *named
# volume*, so a relative path fails with a confusing "refers to undefined volume" error.
# Normalize to absolute here (portably -- no realpath, see extract_if_7z).
case "$RESTORE_PATH" in
    /*) ;;
    *) RESTORE_PATH="$(cd "$(dirname "$RESTORE_PATH")" && pwd)/$(basename "$RESTORE_PATH")" ;;
esac

refuse_if_data_volumes_exist restore-dump

RESOLVED_PATH=$(extract_if_7z "$RESTORE_PATH")
export RESTORE_DUMP_PATH="$RESOLVED_PATH"
case "$RESOLVED_PATH" in
    *.gz) export RESTORE_DUMP_FILENAME="dump.sql.gz" ;;
    *)    export RESTORE_DUMP_FILENAME="dump.sql" ;;
esac
COMPOSE_FILES+=(-f "$MODES_DIR/restore-dump.yaml")
docker compose "${COMPOSE_FILES[@]}" up -d openmrs-db

# A failed attempt is torn down here too (not just on success), so the instance is left in the
# same state either way -- but note this does NOT remove the db-data volume, so a retry still
# requires `destroy` first, exactly like `initialize`.
wait_for_openmrs_db_healthy restored remove_restore_scratch

# Leaves the stack down, the same way `initialize` does -- this is a one-shot data-loading
# operation, and openmrs-db is running against a throwaway overlay (a bind-mounted dump) that
# shouldn't outlive it. This `down` (no -v, so the restored db-data volume survives) also makes
# removing the extraction scratch dir below safe: for a .7z dump restore that directory is the
# bind-mount source openmrs-db is still holding open.
docker compose "${COMPOSE_FILES[@]}" down
remove_restore_scratch
echo "Restored $NAME's openmrs-db from $RESTORE_PATH. Run '$0 $NAME start' to bring the instance up."
