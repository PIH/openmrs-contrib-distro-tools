#!/bin/bash
# Dumps a MySQL/MariaDB database, with its routines and triggers, to a file usable as
# `openmrs-docker <name> initialize`'s RESTORE_MYSQL_DUMP_PATH. The dump has no CREATE DATABASE or
# USE, so it restores into a database of any name.
#
# Usage: openmrs-utils backup-mysqldump (--container=<name> | --host=<host> [--port=3306]
#            [--client-image=mysql:5.6]) --output=<file> [--database=openmrs] [--user=root]
#            [--strip-definers]
#   --output          .sql, .gz (gzipped SQL), or .7z (encrypted, holding <name>.sql, and
#                     streamed in, so the dump is never on disk unencrypted)
#   --strip-definers  removes DEFINER= clauses as it dumps, so the routines and triggers work on a
#                     server without the source's accounts (see strip-mysqldump-definers)
#   MYSQL_PASSWORD    password for --user (default: openmrs)
#   ARCHIVE_PASSWORD  password for a .7z (required for one; on 7z's command line while it runs)
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/mysql.sh
. "$UTILS_DIR/lib/mysql.sh"
# shellcheck source=lib/archive.sh
. "$UTILS_DIR/lib/archive.sh"

OUTPUT=
DATABASE=openmrs
STRIP_DEFINERS=false
for arg in "$@"; do
    case "$arg" in
        --output=*) OUTPUT="${arg#*=}" ;;
        --database=*) DATABASE="${arg#*=}" ;;
        --user=*) DB_USER="${arg#*=}" ;;
        --client-image=*) DB_CLIENT_IMAGE="${arg#*=}" ;;
        --strip-definers) STRIP_DEFINERS=true ;;
        *) mysql_source_arg "$arg" || die "unknown argument: $arg" ;;
    esac
done
mysql_source_given && [ -n "$OUTPUT" ] || usage
case "$OUTPUT" in
    *.gz.7z) die "--output must not end in .gz.7z (7z already compresses) -- use .sql.7z instead" ;;
    *.sql|*.gz) ;;
    *.7z) [ -n "${ARCHIVE_PASSWORD:-}" ] || die "ARCHIVE_PASSWORD must be set to produce a .7z output" ;;
    *) die "--output must end in .sql, .gz or .7z" ;;
esac
OUTPUT=$(abs_path "$OUTPUT")
prepare_output_file "$OUTPUT"
mysql_connect "${MYSQL_PASSWORD:-openmrs}"

# --single-transaction: a consistent snapshot, without locking tables. --flush-logs: starts a new
# binlog, a clean point for purging the older ones.
dump() {
    mysql_dump --single-transaction --flush-logs --routines --triggers "$DATABASE" |
        if $STRIP_DEFINERS; then strip_definers; else cat; fi
}

note "Backing up $MYSQL_SOURCE's $DATABASE database to $OUTPUT..."
case "$OUTPUT" in
    *.7z)
        NAME=$(basename "$OUTPUT" .7z)
        dump | archive_7z_from_stdin "$OUTPUT" "${NAME%.sql}.sql"
        ;;
    *.gz) dump | gzip > "$OUTPUT" ;;
    *) dump > "$OUTPUT" ;;
esac
note "Backed up $MYSQL_SOURCE's $DATABASE database to $OUTPUT."
