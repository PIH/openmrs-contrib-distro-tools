#!/bin/bash
# General-purpose: dumps a running MySQL container's database to a local SQL file, directly
# usable as `openmrs-docker <name> initialize`'s RESTORE_MYSQL_DUMP_PATH. Usage:
#   utils/backup-mysqldump.sh --container=<name> --output=<path> [--database=openmrs] [--user=root]
#
# --output determines the output format: a plain, gzip-compressed .sql.gz for any other
# extension, or a password-protected .7z (matching PIH's existing backup convention) if --output
# ends in .7z, in which case ARCHIVE_PASSWORD (env var, required) is used to encrypt it. The dump
# itself is streamed straight into whichever compressor -- it's never written to disk unencrypted.
#
# MYSQL_PASSWORD (env var, not a named argument -- a secret, so it never shows up in `ps` output)
# authenticates as --user; defaults to "openmrs" if unset.
set -euo pipefail

CONTAINER=
OUTPUT_PATH=
DATABASE=openmrs
DB_USER=root
for arg in "$@"; do
    case "$arg" in
        --container=*) CONTAINER="${arg#*=}" ;;
        --output=*) OUTPUT_PATH="${arg#*=}" ;;
        --database=*) DATABASE="${arg#*=}" ;;
        --user=*) DB_USER="${arg#*=}" ;;
        *) echo "unknown argument: $arg" >&2; exit 1 ;;
    esac
done
usage() { echo "usage: $0 --container=<name> --output=<path> [--database=openmrs] [--user=root]" >&2; exit 1; }
[ -z "$CONTAINER" ] && usage
[ -z "$OUTPUT_PATH" ] && usage

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
# the tables. --flush-logs rotates the binlog at the start of the dump, so it marks a clean
# boundary for later binlog purging. --routines/--triggers give a fuller backup than table data
# alone. MYSQL_PWD rather than -p: container process arguments show up in the host's ps output.
#
# This dump is a faithful, unmodified copy -- notably, --routines/--triggers keep their original
# DEFINER=`user`@`host` clauses, which can fail to restore if that account doesn't exist on the
# target server. That's handled as a separate, optional step at restore time instead of here (see
# utils/strip-mysqldump-definers.sh) rather than silently rewriting every backup this script
# produces, whether or not it ever hits that problem.
DUMP_CMD=(docker exec -e MYSQL_PWD="${MYSQL_PASSWORD:-openmrs}" "$CONTAINER" \
    mysqldump "-u$DB_USER" --single-transaction --flush-logs --routines --triggers "$DATABASE")

case "$OUTPUT_PATH" in
    *.7z)
        [ -z "${ARCHIVE_PASSWORD:-}" ] && { echo "error: ARCHIVE_PASSWORD must be set to produce a .7z output" >&2; exit 1; }
        DIR=$(dirname "$OUTPUT_PATH")
        "${DUMP_CMD[@]}" | docker run -i --rm \
            -e ARCHIVE_PW="$ARCHIVE_PASSWORD" -e OUT_NAME="$(basename "$OUTPUT_PATH")" \
            -v "$DIR:/out" \
            alpine:3.21 \
            sh -c 'apk add --no-cache p7zip >/dev/null && 7z a -si"dump.sql" -p"$ARCHIVE_PW" -mx5 -t7z "/out/$OUT_NAME"' >&2
        ;;
    *)
        "${DUMP_CMD[@]}" | gzip > "$OUTPUT_PATH"
        ;;
esac
echo "Backed up $CONTAINER's $DATABASE database to $OUTPUT_PATH."
