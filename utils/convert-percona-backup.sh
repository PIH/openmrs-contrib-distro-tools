#!/bin/bash
# Turns a prepared (--apply-log'd) XtraBackup backup directory, from backup-percona or a legacy
# nightly backup, into a MySQL data directory (innobackupex --copy-back), usable as initialize's
# RESTORE_MYSQL_DATA_PATH. Prints the data directory's path.
#
# Usage: openmrs-utils convert-percona-backup --backup-dir=<dir> --output-dir=<new dir>
#   The output is written as root: reclaim it (chown) before removing it as another user.
#   SKIP_DISK_SPACE_CHECK=true  skips the free-space check
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/disk-space.sh
. "$UTILS_DIR/lib/disk-space.sh"

BACKUP_DIR=
OUTPUT_DIR=
for arg in "$@"; do
    case "$arg" in
        --backup-dir=*) BACKUP_DIR="${arg#*=}" ;;
        --output-dir=*) OUTPUT_DIR="${arg#*=}" ;;
        *) die "unknown argument: $arg" ;;
    esac
done
[ -n "$BACKUP_DIR" ] && [ -n "$OUTPUT_DIR" ] || usage
[ -d "$BACKUP_DIR" ] || die "no such directory: $BACKUP_DIR"
[ ! -e "$OUTPUT_DIR" ] || die "$OUTPUT_DIR already exists"
BACKUP_DIR=$(cd "$BACKUP_DIR" && pwd)
OUTPUT_DIR=$(abs_path "$OUTPUT_DIR")
disk_space_require "converting $BACKUP_DIR (a full copy)" "$(disk_space_size_of "$BACKUP_DIR")" \
    "$(disk_space_free_at "$OUTPUT_DIR")" "the filesystem of $OUTPUT_DIR"
prepare_output_dir "$OUTPUT_DIR"

note "Converting $BACKUP_DIR into a MySQL data directory at $OUTPUT_DIR..."
# --copy-back, not --move-back: the backup is mounted read-only, and --move-back would print a
# spurious "Error: unlink ... failed" for every file.
docker run --rm -v "$BACKUP_DIR:/opt/backup:ro" -v "$OUTPUT_DIR:/var/lib/mysql" "$PERCONA_IMAGE" \
    innobackupex --copy-back --datadir=/var/lib/mysql /opt/backup >&2
echo "$OUTPUT_DIR"
