#!/bin/bash
# Takes a physical (XtraBackup) backup of a running MySQL server's data directory and prepares it
# (--apply-log): as a directory, for convert-percona-backup, or as an encrypted .7z in the legacy
# nightly percona.7z layout (the backup's files at the top level), which initialize's
# RESTORE_MYSQL_PERCONA_PATH and the legacy DW refresh take.
#
# Usage: openmrs-utils backup-percona (--container=<name> | --host=<host> [--port=3306])
#            --volume=<volume or dir> --output=<new dir | file.7z> [--databases=<list>]
#   --volume             the server's data directory (a volume or absolute path), which
#                        XtraBackup reads directly
#   --output             a new directory, or a .7z (made from a temporary volume, so the backup is
#                        never on the host unencrypted)
#   --databases          a space-separated list to back up, instead of all (mysql and
#                        performance_schema are added: a restore without mysql has no accounts)
#   MYSQL_ROOT_PASSWORD  root's password (default: openmrs)
#   ARCHIVE_PASSWORD     password for a .7z (required for one)
#   SKIP_DISK_SPACE_CHECK=true  skips the free-space check
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/mysql.sh
. "$UTILS_DIR/lib/mysql.sh"
# shellcheck source=lib/disk-space.sh
. "$UTILS_DIR/lib/disk-space.sh"
# shellcheck source=lib/archive.sh
. "$UTILS_DIR/lib/archive.sh"

VOLUME=
OUTPUT=
DATABASES=
for arg in "$@"; do
    case "$arg" in
        --volume=*) VOLUME="${arg#*=}" ;;
        --output=*) OUTPUT="${arg#*=}" ;;
        --databases=*) DATABASES="${arg#*=}" ;;
        *) mysql_source_arg "$arg" || die "unknown argument: $arg" ;;
    esac
done
mysql_source_given && [ -n "$VOLUME" ] && [ -n "$OUTPUT" ] || usage
OUTPUT=$(abs_path "$OUTPUT")
[ ! -e "$OUTPUT" ] || die "$OUTPUT already exists"
ARCHIVE=false
case "$OUTPUT" in
    *.7z)
        ARCHIVE=true
        [ -n "${ARCHIVE_PASSWORD:-}" ] || die "ARCHIVE_PASSWORD must be set to produce a .7z output"
        ;;
esac

# The whole data directory, even with --databases, so this errs on the side of refusing. A .7z's
# temporary volume and the archive are both checked against it.
NEEDED_KB=$(disk_space_size_of "$VOLUME")
if $ARCHIVE; then
    disk_space_require "a physical backup of $VOLUME (in a temporary volume)" "$NEEDED_KB" \
        "$(disk_space_free_on_docker_volumes)" "Docker's volumes"
fi
disk_space_require "a physical backup of $VOLUME" "$NEEDED_KB" \
    "$(disk_space_free_at "$OUTPUT")" "the filesystem of $OUTPUT"

if $ARCHIVE; then
    prepare_output_file "$OUTPUT"
    BACKUP="backup-percona-$(date +%Y%m%d%H%M%S)-$$"   # the temporary volume
    docker volume create "$BACKUP" >/dev/null
    on_exit 'docker volume rm -f "$BACKUP" >/dev/null 2>&1'
else
    prepare_output_dir "$OUTPUT"
    BACKUP=$OUTPUT
fi

if [ -n "$DATABASES" ]; then
    for db in mysql performance_schema; do
        case " $DATABASES " in *" $db "*) ;; *) DATABASES+=" $db" ;; esac
    done
fi
if [ -n "$DB_CONTAINER" ]; then
    # In the container's network namespace, where its server is on 127.0.0.1.
    NETWORK=(--network "container:$DB_CONTAINER")
    CONNECT_HOST=127.0.0.1 CONNECT_PORT=3306
else
    NETWORK=(--network host)
    CONNECT_HOST=$DB_HOST CONNECT_PORT=$DB_PORT
fi

note "Backing up $MYSQL_SOURCE (physical/xtrabackup) to $OUTPUT..."
MYSQL_PWD="${MYSQL_ROOT_PASSWORD:-openmrs}" BACKUP_DATABASES="$DATABASES" docker run --rm "${NETWORK[@]}" \
    -e MYSQL_PWD -e BACKUP_DATABASES -e CONNECT_HOST="$CONNECT_HOST" -e CONNECT_PORT="$CONNECT_PORT" \
    -v "$VOLUME:/var/lib/mysql:ro" -v "$BACKUP:/backup" "$PERCONA_IMAGE" \
    sh -c 'set -- --user=root --host="$CONNECT_HOST" --port="$CONNECT_PORT"
           [ -n "$BACKUP_DATABASES" ] && set -- "$@" --databases="$BACKUP_DATABASES"
           innobackupex "$@" /backup' >&2

# innobackupex wrote into a timestamped subdirectory. Its contents move up, so the backup is
# usable as is and archives flat (cp and rm, since `mv sub/*` would skip dotfiles).
docker run --rm -v "$BACKUP:/backup" "$ALPINE_IMAGE" sh -c '
    sub=$(find /backup -mindepth 1 -maxdepth 1 -type d | head -1)
    [ -z "$sub" ] || { cp -a "$sub/." /backup/ && rm -rf "$sub"; }' >&2

note "Preparing backup (applying transaction log)..."
docker run --rm -v "$BACKUP:/backup" "$PERCONA_IMAGE" innobackupex --apply-log /backup >&2

if $ARCHIVE; then
    note "Archiving to $OUTPUT..."
    archive_7z_create "$OUTPUT" "$BACKUP" ''
    note "Backed up $MYSQL_SOURCE to $OUTPUT (for initialize's RESTORE_MYSQL_PERCONA_PATH)."
else
    # --apply-log leaves the directory root-owned and closed to others, like a real data directory.
    docker run --rm -v "$OUTPUT:/target" "$ALPINE_IMAGE" chown -R "$(id -u):$(id -g)" /target >&2
    note "Backed up $MYSQL_SOURCE to $OUTPUT (ready for convert-percona-backup, or initialize's RESTORE_MYSQL_PERCONA_PATH)."
fi
