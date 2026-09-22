#!/bin/bash
# General-purpose: takes a physical (xtrabackup) backup of a running MySQL container's data
# volume into a local directory, already prepared (--apply-log) so it's directly usable as input
# to utils/convert-percona-backup.sh. Usage:
#   utils/backup-percona.sh --container=<name> --volume=<db data volume name> --output=<dir>
#
# MYSQL_ROOT_PASSWORD (env var, not a named argument -- a secret) authenticates as root; defaults
# to "openmrs" if unset. Passed to the container as a bare `-e MYSQL_ROOT_PASSWORD` (inheriting
# the already-set value from this script's own environment) rather than `-e VAR=value` or a
# `--password=` command argument, so the value itself never appears in `docker`'s argv -- and so
# never shows up in `ps` output, which shows argv but not environment.
set -euo pipefail

CONTAINER=
VOLUME=
OUTPUT_DIR=
for arg in "$@"; do
    case "$arg" in
        --container=*) CONTAINER="${arg#*=}" ;;
        --volume=*) VOLUME="${arg#*=}" ;;
        --output=*) OUTPUT_DIR="${arg#*=}" ;;
        *) echo "unknown argument: $arg" >&2; exit 1 ;;
    esac
done
usage() { echo "usage: $0 --container=<name> --volume=<db data volume name> --output=<dir>" >&2; exit 1; }
[ -z "$CONTAINER" ] && usage
[ -z "$VOLUME" ] && usage
[ -z "$OUTPUT_DIR" ] && usage

case "$OUTPUT_DIR" in
    /*) ;;
    *) OUTPUT_DIR="$(pwd)/$OUTPUT_DIR" ;;
esac
[ -e "$OUTPUT_DIR" ] && { echo "error: $OUTPUT_DIR already exists" >&2; exit 1; }
mkdir -p "$OUTPUT_DIR"

echo "Backing up $CONTAINER (physical/xtrabackup) to $OUTPUT_DIR..." >&2
# Shares the container's network namespace so it can reach it at 127.0.0.1, and mounts its
# actual data directory read-only -- innobackupex needs real filesystem access to the datadir
# it's backing up, not just a network connection to the running mysqld.
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-openmrs}" docker run --rm --network "container:$CONTAINER" \
    -e MYSQL_ROOT_PASSWORD \
    -v "$VOLUME:/var/lib/mysql:ro" \
    -v "$OUTPUT_DIR:/backup" \
    partnersinhealth/percona-0.1-4 \
    sh -c 'innobackupex --user=root --password="$MYSQL_ROOT_PASSWORD" --host=127.0.0.1 /backup' >&2

# innobackupex writes into a timestamped subdirectory of the given target, owned by the
# container's root -- move its contents up one level (in a container, so this works regardless
# of host/container UID mismatches) so the result is directly usable as convert-percona-backup.sh's
# --backup-dir. cp+rm rather than `mv .../*`, which silently skips dotfiles.
BACKUP_SUBDIR_NAME=$(docker run --rm -v "$OUTPUT_DIR:/backup" alpine:3.21 \
    sh -c 'find /backup -mindepth 1 -maxdepth 1 -type d | head -1 | xargs -r basename')
if [ -n "$BACKUP_SUBDIR_NAME" ]; then
    docker run --rm -e SUBDIR="$BACKUP_SUBDIR_NAME" -v "$OUTPUT_DIR:/backup" alpine:3.21 \
        sh -c 'cp -a "/backup/$SUBDIR/." /backup/ && rm -rf "/backup/$SUBDIR"' >&2
fi

echo "Preparing backup (applying transaction log)..." >&2
docker run --rm -v "$OUTPUT_DIR:/backup" partnersinhealth/percona-0.1-4 innobackupex --apply-log /backup >&2

# --apply-log leaves $OUTPUT_DIR itself root-owned with restrictive permissions (xtrabackup
# hardens it to look like a real mysql datadir) -- reclaim it for whoever's running this script,
# or convert-percona-backup.sh's very first `cd "$BACKUP_DIR"` on the result fails outright.
docker run --rm -v "$OUTPUT_DIR:/target" alpine:3.21 chown -R "$(id -u):$(id -g)" /target >&2

echo "Backed up $CONTAINER to $OUTPUT_DIR (ready for utils/convert-percona-backup.sh)." >&2
