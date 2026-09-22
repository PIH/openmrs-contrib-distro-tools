#!/bin/bash
# General-purpose: dumps a running MySQL container's database to a local, gzip-compressed SQL
# file, directly usable as `openmrs-docker <name> initialize`'s RESTORE_MYSQL_DUMP_PATH. Usage:
#   utils/backup-mysqldump.sh --container=<name> --output=<path> [--database=openmrs]
#
# MYSQL_ROOT_PASSWORD (env var, not a named argument -- a secret, so it never shows up in `ps`
# output) authenticates as root; defaults to "openmrs" if unset.
set -euo pipefail

CONTAINER=
OUTPUT_PATH=
DATABASE=openmrs
for arg in "$@"; do
    case "$arg" in
        --container=*) CONTAINER="${arg#*=}" ;;
        --output=*) OUTPUT_PATH="${arg#*=}" ;;
        --database=*) DATABASE="${arg#*=}" ;;
        *) echo "unknown argument: $arg" >&2; exit 1 ;;
    esac
done
[ -z "$CONTAINER" ] && { echo "usage: $0 --container=<name> --output=<path> [--database=openmrs]" >&2; exit 1; }
[ -z "$OUTPUT_PATH" ] && { echo "usage: $0 --container=<name> --output=<path> [--database=openmrs]" >&2; exit 1; }

case "$OUTPUT_PATH" in
    /*) ;;
    *) OUTPUT_PATH="$(pwd)/$OUTPUT_PATH" ;;
esac
[ -e "$OUTPUT_PATH" ] && { echo "error: $OUTPUT_PATH already exists" >&2; exit 1; }
mkdir -p "$(dirname "$OUTPUT_PATH")"

echo "Backing up $CONTAINER's $DATABASE database to $OUTPUT_PATH..."
# A bare database name (rather than --databases) omits the CREATE DATABASE/USE statements, so the
# dump contains only table data and can be restored into any already-selected database --
# including one named differently from the source, and matching how MySQL's own docker-entrypoint
# imports a RESTORE_MYSQL_DUMP_PATH dump into whatever MYSQL_DATABASE the target container
# already has configured. --single-transaction takes a consistent InnoDB snapshot without locking
# the tables. MYSQL_PWD rather than -p: container process arguments show up in the host's ps
# output.
docker exec -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD:-openmrs}" "$CONTAINER" \
    mysqldump -uroot --single-transaction --routines --triggers "$DATABASE" \
    | gzip > "$OUTPUT_PATH"
echo "Backed up $CONTAINER's $DATABASE database to $OUTPUT_PATH."
