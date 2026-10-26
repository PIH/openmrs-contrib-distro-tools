#!/bin/bash
# Dumps a DHIS2 database from its Postgres container to a file usable as `openmrs-docker <name>
# initialize`'s RESTORE_PGDUMP_PATH: plain SQL, without owners or privileges (pg_dump -O -x) or DROP
# statements, so it restores into any empty database, and without the tables DHIS2 regenerates when
# analytics runs (much smaller).
#
# Usage: openmrs-utils backup-pgdump --container=<name> --output=<file> [--database=dhis] [--user=dhis]
#            [--exclude-table=<pattern>]... [--no-default-excludes]
#   --container       a running Postgres container (an instance's <name>-dhis2-db)
#   --output          .sql, .gz (gzipped SQL), or .7z (encrypted, holding <name>.sql, and streamed
#                     in, so the dump is never on disk unencrypted)
#   --exclude-table   a pg_dump table pattern to leave out, besides the defaults
#   --no-default-excludes  keeps analytics_*, aggregated* and completeness*, left out by default
#   The password is the container's own POSTGRES_PASSWORD, read inside it.
#   ARCHIVE_PASSWORD  password for a .7z (required for one; on 7z's command line while it runs)
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/archive.sh
. "$UTILS_DIR/lib/archive.sh"

CONTAINER=""
OUTPUT=""
DATABASE=dhis
DB_USER=dhis
EXCLUDES=()
DEFAULT_EXCLUDES=true
for arg in "$@"; do
    case "$arg" in
        --container=*) CONTAINER="${arg#*=}" ;;
        --output=*) OUTPUT="${arg#*=}" ;;
        --database=*) DATABASE="${arg#*=}" ;;
        --user=*) DB_USER="${arg#*=}" ;;
        --exclude-table=*) EXCLUDES+=("${arg#*=}") ;;
        --no-default-excludes) DEFAULT_EXCLUDES=false ;;
        *) die "unknown argument: $arg" ;;
    esac
done
[ -n "$CONTAINER" ] && [ -n "$OUTPUT" ] || usage
case "$OUTPUT" in
    *.gz.7z) die "--output must not end in .gz.7z (7z already compresses) -- use .sql.7z instead" ;;
    *.sql|*.gz) ;;
    *.7z) [ -n "${ARCHIVE_PASSWORD:-}" ] || die "ARCHIVE_PASSWORD must be set to produce a .7z output" ;;
    *) die "--output must end in .sql, .gz or .7z" ;;
esac
! $DEFAULT_EXCLUDES || EXCLUDES+=('analytics_*' 'aggregated*' 'completeness*')
OUTPUT=$(abs_path "$OUTPUT")
prepare_output_file "$OUTPUT"

# Arguments go to the container's shell as positional parameters; the password never leaves it.
dump() {
    local args=(-O -x --no-password -U "$DB_USER" -d "$DATABASE") pattern
    for pattern in "${EXCLUDES[@]}"; do args+=(-T "$pattern"); done
    # shellcheck disable=SC2016 # expanded in the container
    docker exec "$CONTAINER" sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" exec pg_dump -h 127.0.0.1 "$@"' sh "${args[@]}"
}

note "Backing up $CONTAINER's $DATABASE database to $OUTPUT..."
case "$OUTPUT" in
    *.7z)
        NAME=$(basename "$OUTPUT" .7z)
        dump | archive_7z_from_stdin "$OUTPUT" "${NAME%.sql}.sql"
        ;;
    *.gz) dump | gzip > "$OUTPUT" ;;
    *) dump > "$OUTPUT" ;;
esac
note "Backed up $CONTAINER's $DATABASE database to $OUTPUT."
