#!/bin/bash
# General-purpose: takes a physical (xtrabackup) backup of a running MySQL server's data directory,
# already prepared (--apply-log), either as a directory (input to utils/convert-percona-backup.sh)
# or as a password-protected .7z (what openmrs-docker initialize's RESTORE_MYSQL_PERCONA_PATH, and
# the legacy DW refresh scripts, take). Usage:
#   utils/backup-percona.sh (--container=<name> | --host=<host> [--port=3306])
#       --volume=<db data volume or host dir> --output=<dir | path.7z> [--databases=<list>]
#
# --container backs up a MySQL container, sharing its network namespace to reach it at 127.0.0.1.
# --host instead connects over TCP with host networking -- e.g. --host=127.0.0.1 for a MySQL
# installed directly on a legacy host, with --volume=/var/lib/mysql.
#
# --volume is the server's data directory, which xtrabackup reads directly (it needs the files, not
# just a connection); passed straight through as `docker run -v`'s source, so it works equally as a
# named Docker volume or an absolute host directory path. Mounted read-only.
#
# --output ending in .7z writes a password-protected archive (ARCHIVE_PASSWORD env var, required)
# in the legacy nightly backup's layout: prepared, with the backup's files at the top level, and
# encrypted with -p (the file list isn't). The backup is taken and prepared in a temporary Docker
# volume and archived from there, so it's never on the host unencrypted; the volume is removed
# afterwards, whether or not the backup succeeds. Anything else is an output directory, which must
# not exist yet. A failed backup never leaves a partial output behind.
#
# --databases (optional) limits the backup to a space-separated list of database names (e.g.
# "openmrs"), passed through to innobackupex's own --databases option with the mysql and
# performance_schema system databases added -- innobackupex itself backs up only exactly what's
# listed, and a datadir restored without mysql comes up with no usable accounts. Omit it to back up
# every database.
#
# MYSQL_ROOT_PASSWORD (env var, not a named argument -- a secret) authenticates as root; defaults
# to "openmrs" if unset. Secrets are passed to `docker` as a bare `-e VARNAME` (inheriting the
# already-set value from this script's own environment) rather than `-e VAR=value` or a
# `--password=` command argument, so the values never appear in `docker`'s argv -- and so never
# show up in `ps` output, which shows argv but not environment.
set -euo pipefail
# shellcheck source=lib/disk-space.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/disk-space.sh"

CONTAINER=
DB_HOST=
DB_PORT=3306
VOLUME=
OUTPUT=
DATABASES=
for arg in "$@"; do
    case "$arg" in
        --container=*) CONTAINER="${arg#*=}" ;;
        --host=*) DB_HOST="${arg#*=}" ;;
        --port=*) DB_PORT="${arg#*=}" ;;
        --volume=*) VOLUME="${arg#*=}" ;;
        --output=*) OUTPUT="${arg#*=}" ;;
        --databases=*) DATABASES="${arg#*=}" ;;
        *) echo "unknown argument: $arg" >&2; exit 1 ;;
    esac
done
usage() { echo "usage: $0 (--container=<name> | --host=<host> [--port=3306]) --volume=<db data volume or host dir> --output=<dir | path.7z> [--databases=<list>]" >&2; exit 1; }
[ -z "$CONTAINER" ] && [ -z "$DB_HOST" ] && usage
[ -n "$CONTAINER" ] && [ -n "$DB_HOST" ] && { echo "error: pass either --container or --host, not both" >&2; exit 1; }
[ -z "$VOLUME" ] && usage
[ -z "$OUTPUT" ] && usage

case "$OUTPUT" in
    /*) ;;
    *) OUTPUT="$(pwd)/$OUTPUT" ;;
esac
[ -e "$OUTPUT" ] && { echo "error: $OUTPUT already exists" >&2; exit 1; }
ARCHIVE=false
case "$OUTPUT" in
    *.7z)
        ARCHIVE=true
        [ -n "${ARCHIVE_PASSWORD:-}" ] || { echo "error: ARCHIVE_PASSWORD must be set to produce a .7z output" >&2; exit 1; }
        ;;
esac

# The whole data directory, even with --databases: a limited backup is smaller, so this only errs
# on the side of refusing (SKIP_DISK_SPACE_CHECK=true then). For a .7z, the temporary volume holds
# the backup and the archive is smaller, but both are checked against the full size.
NEEDED_KB=$(disk_space_size_of "$VOLUME")
if $ARCHIVE; then
    disk_space_require "a physical backup of $VOLUME (in a temporary volume)" "$NEEDED_KB" \
        "$(disk_space_free_on_docker_volumes)" "Docker's volumes"
fi
disk_space_require "a physical backup of $VOLUME" "$NEEDED_KB" \
    "$(disk_space_free_at "$OUTPUT")" "the filesystem of $OUTPUT"

if $ARCHIVE; then
    # The backup is taken and prepared here, then archived into $OUTPUT; removed whatever happens.
    TARGET="backup-percona-$(date +%Y%m%d%H%M%S)-$$"
    docker volume create "$TARGET" >/dev/null
    trap 'docker volume rm -f "$TARGET" >/dev/null 2>&1 || true' EXIT
    trap 'rm -f "$OUTPUT"' ERR
    mkdir -p "$(dirname "$OUTPUT")"
else
    TARGET="$OUTPUT"
    mkdir -p "$OUTPUT"
    # A failed backup leaves a partial directory that looks like a real one -- remove it on any
    # error. Via a container, since innobackupex writes its contents as root.
    trap 'docker run --rm -v "$OUTPUT:/t" alpine:3.21 find /t -mindepth 1 -delete >/dev/null 2>&1; rm -rf "$OUTPUT"' ERR
fi

if [ -n "$DATABASES" ]; then
    for db in mysql performance_schema; do
        case " $DATABASES " in
            *" $db "*) ;;
            *) DATABASES="$DATABASES $db" ;;
        esac
    done
fi

if [ -n "$CONTAINER" ]; then
    SOURCE="$CONTAINER"
    NETWORK=(--network "container:$CONTAINER")
    CONNECT_HOST=127.0.0.1 CONNECT_PORT=3306
else
    SOURCE="$DB_HOST:$DB_PORT"
    NETWORK=(--network host)
    CONNECT_HOST="$DB_HOST" CONNECT_PORT="$DB_PORT"
fi

echo "Backing up $SOURCE (physical/xtrabackup) to $OUTPUT..." >&2
# Mounts the server's actual data directory read-only -- innobackupex needs real filesystem access
# to the datadir it's backing up, not just a network connection to the running mysqld.
#
# BACKUP_DATABASES is built into the argument list with `set --` (rather than interpolating it
# into a conditional flag string) so a multi-database value with spaces stays one argument to
# --databases -- embedding it inside a quoted expansion instead would have the shell re-split it
# on those same spaces.
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-openmrs}" BACKUP_DATABASES="$DATABASES" docker run --rm \
    "${NETWORK[@]}" \
    -e MYSQL_ROOT_PASSWORD -e BACKUP_DATABASES -e CONNECT_HOST="$CONNECT_HOST" -e CONNECT_PORT="$CONNECT_PORT" \
    -v "$VOLUME:/var/lib/mysql:ro" \
    -v "$TARGET:/backup" \
    partnersinhealth/percona-0.1-4 \
    sh -c 'set -- --user=root --password="$MYSQL_ROOT_PASSWORD" --host="$CONNECT_HOST" --port="$CONNECT_PORT"
           [ -n "$BACKUP_DATABASES" ] && set -- "$@" --databases="$BACKUP_DATABASES"
           innobackupex "$@" /backup' >&2

# innobackupex writes into a timestamped subdirectory of the given target, owned by the
# container's root -- move its contents up one level (in a container, so this works regardless
# of host/container UID mismatches) so the result is directly usable as convert-percona-backup.sh's
# --backup-dir, and archives flat. cp+rm rather than `mv .../*`, which silently skips dotfiles.
BACKUP_SUBDIR_NAME=$(docker run --rm -v "$TARGET:/backup" alpine:3.21 \
    sh -c 'find /backup -mindepth 1 -maxdepth 1 -type d | head -1 | xargs -r basename')
if [ -n "$BACKUP_SUBDIR_NAME" ]; then
    docker run --rm -e SUBDIR="$BACKUP_SUBDIR_NAME" -v "$TARGET:/backup" alpine:3.21 \
        sh -c 'cp -a "/backup/$SUBDIR/." /backup/ && rm -rf "/backup/$SUBDIR"' >&2
fi

echo "Preparing backup (applying transaction log)..." >&2
docker run --rm -v "$TARGET:/backup" partnersinhealth/percona-0.1-4 innobackupex --apply-log /backup >&2

if $ARCHIVE; then
    echo "Archiving to $OUTPUT..." >&2
    # The backup's files at the archive's top level, encrypted with -p: the legacy percona.7z layout.
    ARCHIVE_PW="$ARCHIVE_PASSWORD" docker run --rm \
        -e ARCHIVE_PW -e OUT_NAME="$(basename "$OUTPUT")" -e OWNER="$(id -u):$(id -g)" \
        -v "$TARGET:/backup:ro" -v "$(dirname "$OUTPUT"):/out" -w /backup \
        partnersinhealth/p7zip \
        sh -c '7z a -p"$ARCHIVE_PW" -mx5 -t7z "/out/$OUT_NAME" ./* >/dev/null && chown "$OWNER" "/out/$OUT_NAME"' >&2
    echo "Backed up $SOURCE to $OUTPUT (for initialize's RESTORE_MYSQL_PERCONA_PATH)." >&2
else
    # --apply-log leaves $OUTPUT itself root-owned with restrictive permissions (xtrabackup
    # hardens it to look like a real mysql datadir) -- reclaim it for whoever's running this
    # script, or convert-percona-backup.sh's very first `cd "$BACKUP_DIR"` on the result fails.
    docker run --rm -v "$OUTPUT:/target" alpine:3.21 chown -R "$(id -u):$(id -g)" /target >&2
    echo "Backed up $SOURCE to $OUTPUT (ready for utils/convert-percona-backup.sh, or initialize's RESTORE_MYSQL_PERCONA_PATH)." >&2
fi
