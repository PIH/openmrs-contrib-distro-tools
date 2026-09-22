#!/bin/bash
# Usage: openmrs-docker <name> openmrs-db backup-mysqldump <output-path>
#
# Dumps this instance's running openmrs-db database to a local, gzip-compressed SQL file,
# usable directly as input to a later restore-dump (on this or another instance). Sourced into
# bin/openmrs-docker, not run standalone: relies on COMPOSE_FILES, NAME, and SERVICE_NAME/
# OPENMRS_DB_ROOT_PASSWORD (from the instance's env file) already being in scope.
set -euo pipefail

OUTPUT_PATH="${1:-}"
[ -z "$OUTPUT_PATH" ] && { echo "usage: $0 $NAME openmrs-db backup-mysqldump <output-path>" >&2; exit 1; }

DB_CONTAINER=$(docker compose "${COMPOSE_FILES[@]}" ps -q openmrs-db)
[ -z "$DB_CONTAINER" ] && { echo "error: openmrs-db is not running -- start the instance first ('$0 $NAME start')." >&2; exit 1; }

case "$OUTPUT_PATH" in
    /*) ;;
    *) OUTPUT_PATH="$(pwd)/$OUTPUT_PATH" ;;
esac
[ -e "$OUTPUT_PATH" ] && { echo "error: $OUTPUT_PATH already exists" >&2; exit 1; }
mkdir -p "$(dirname "$OUTPUT_PATH")"

echo "Backing up ${SERVICE_NAME}'s openmrs-db to $OUTPUT_PATH..."
# --databases (rather than a bare database name) includes a CREATE DATABASE statement, so the
# dump is self-contained and directly usable by restore-dump on a brand-new instance.
# --single-transaction takes a consistent InnoDB snapshot without locking the tables.
# MYSQL_PWD rather than -p: container process arguments show up in the host's ps output.
docker exec -e MYSQL_PWD="${OPENMRS_DB_ROOT_PASSWORD:-openmrs}" "$DB_CONTAINER" \
    mysqldump -uroot --databases openmrs --single-transaction --routines --triggers \
    | gzip > "$OUTPUT_PATH"
echo "Backed up ${SERVICE_NAME}'s openmrs-db to $OUTPUT_PATH (ready for restore-dump)."
