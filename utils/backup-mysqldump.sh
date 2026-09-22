#!/bin/bash
# General-purpose: dumps a running MySQL container's database to a local SQL file, directly
# usable as `openmrs-docker <name> initialize`'s RESTORE_MYSQL_DUMP_PATH. Usage:
#   utils/backup-mysqldump.sh --container=<name> --output=<path> [--database=openmrs] [--user=root]
#
# --output must end in .gz (plain, gzip-compressed SQL) or .7z (password-protected archive,
# matching PIH's existing backup convention -- ARCHIVE_PASSWORD env var, required). Either way
# the dump is streamed straight into the compressor -- it's never written to disk unencrypted,
# and a failed dump never leaves a partial file behind.
#
# MYSQL_PASSWORD (env var, not a named argument -- a secret) authenticates as --user; defaults to
# "openmrs" if unset. Secrets are passed to `docker` as a bare `-e VARNAME` (inheriting the
# already-set value from this script's own environment) rather than `-e VARNAME=value`, so the
# value itself never appears in `docker`'s argv -- and so never shows up in `ps` output, which
# shows argv but not environment.
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
usage() { echo "usage: $0 --container=<name> --output=<path.gz|path.7z> [--database=openmrs] [--user=root]" >&2; exit 1; }
[ -z "$CONTAINER" ] && usage
[ -z "$OUTPUT_PATH" ] && usage
case "$OUTPUT_PATH" in
    *.gz|*.7z) ;;
    *) echo "error: --output must end in .gz or .7z" >&2; exit 1 ;;
esac

case "$OUTPUT_PATH" in
    /*) ;;
    *) OUTPUT_PATH="$(pwd)/$OUTPUT_PATH" ;;
esac
[ -e "$OUTPUT_PATH" ] && { echo "error: $OUTPUT_PATH already exists" >&2; exit 1; }
mkdir -p "$(dirname "$OUTPUT_PATH")"
# A failed dump/compress leaves nothing but a half-written file that looks like a valid backup --
# clean it up on any error.
trap 'rm -f "$OUTPUT_PATH"' ERR

echo "Backing up $CONTAINER's $DATABASE database to $OUTPUT_PATH..." >&2
# A bare database name (rather than --databases) omits the CREATE DATABASE/USE statements, so the
# dump contains only table data and can be restored into any already-selected database --
# including one named differently from the source, and matching how MySQL's own docker-entrypoint
# imports a RESTORE_MYSQL_DUMP_PATH dump into whatever MYSQL_DATABASE the target container
# already has configured. --single-transaction takes a consistent InnoDB snapshot without locking
# the tables. --flush-logs rotates the binlog at the start of the dump, so it marks a clean
# boundary for later binlog purging. --routines/--triggers give a fuller backup than table data
# alone.
#
# This dump is a faithful, unmodified copy -- notably, --routines/--triggers keep their original
# DEFINER=`user`@`host` clauses, which can fail to restore if that account doesn't exist on the
# target server. That's handled as a separate, optional step at restore time instead of here (see
# utils/strip-mysqldump-definers.sh) rather than silently rewriting every backup this script
# produces, whether or not it ever hits that problem.
DUMP_CMD=(docker exec -e MYSQL_PWD "$CONTAINER" \
    mysqldump "-u$DB_USER" --single-transaction --flush-logs --routines --triggers "$DATABASE")

case "$OUTPUT_PATH" in
    *.7z)
        [ -z "${ARCHIVE_PASSWORD:-}" ] && { echo "error: ARCHIVE_PASSWORD must be set to produce a .7z output" >&2; exit 1; }
        DIR=$(dirname "$OUTPUT_PATH")
        MYSQL_PWD="${MYSQL_PASSWORD:-openmrs}" "${DUMP_CMD[@]}" | ARCHIVE_PW="$ARCHIVE_PASSWORD" docker run -i --rm \
            -e ARCHIVE_PW -e OUT_NAME="$(basename "$OUTPUT_PATH")" \
            -v "$DIR:/out" \
            alpine:3.21 \
            sh -c 'apk add --no-cache p7zip >/dev/null && 7z a -si"dump.sql" -p"$ARCHIVE_PW" -mx5 -t7z "/out/$OUT_NAME"' >&2
        ;;
    *)
        MYSQL_PWD="${MYSQL_PASSWORD:-openmrs}" "${DUMP_CMD[@]}" | gzip > "$OUTPUT_PATH"
        ;;
esac
echo "Backed up $CONTAINER's $DATABASE database to $OUTPUT_PATH." >&2
