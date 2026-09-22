#!/bin/bash
# General-purpose: converts an extracted percona/xtrabackup backup directory (already prepared,
# i.e. --apply-log has already been run against it -- both utils/backup-percona.sh and PIH's
# legacy nightly backup scripts produce backups in this state) into a ready-to-use MySQL data
# directory. Usage:
#   utils/convert-percona-backup.sh --backup-dir=<extracted backup dir> --output-dir=<dir>
#
# --output-dir must not already exist. The result is directly usable as
# `openmrs-docker <name> initialize`'s RESTORE_MYSQL_DATA_PATH, or as the datadir for any other
# MySQL container. The output is written by a container running as root -- reclaim ownership
# (e.g. `docker run --rm -v <output-dir>:/target alpine:3.21 chown -R $(id -u):$(id -g) /target`)
# before trying to remove it as a normal user.
set -euo pipefail

BACKUP_DIR=
OUTPUT_DIR=
for arg in "$@"; do
    case "$arg" in
        --backup-dir=*) BACKUP_DIR="${arg#*=}" ;;
        --output-dir=*) OUTPUT_DIR="${arg#*=}" ;;
        *) echo "unknown argument: $arg" >&2; exit 1 ;;
    esac
done
[ -z "$BACKUP_DIR" ] && { echo "usage: $0 --backup-dir=<extracted backup dir> --output-dir=<dir>" >&2; exit 1; }
[ -z "$OUTPUT_DIR" ] && { echo "usage: $0 --backup-dir=<extracted backup dir> --output-dir=<dir>" >&2; exit 1; }
[ -d "$BACKUP_DIR" ] || { echo "error: no such directory: $BACKUP_DIR" >&2; exit 1; }
[ -e "$OUTPUT_DIR" ] && { echo "error: $OUTPUT_DIR already exists" >&2; exit 1; }
mkdir -p "$OUTPUT_DIR"

BACKUP_DIR_ABS=$(cd "$BACKUP_DIR" && pwd)
OUTPUT_DIR_ABS=$(cd "$OUTPUT_DIR" && pwd)

echo "Converting $BACKUP_DIR_ABS into a MySQL data directory at $OUTPUT_DIR_ABS..." >&2
# --copy-back, not --move-back: /opt/backup is deliberately mounted read-only, and --move-back's
# rename step can't unlink the source, so it falls back to copy + a failed delete -- succeeding
# overall but emitting a spurious "Error: unlink ... failed" line per file.
# Redirected to stderr like every other utils/ script's own output: this script's stdout is the
# result path, captured via $(...) by callers (see the usage note above).
docker run --rm \
    -v "$BACKUP_DIR_ABS:/opt/backup:ro" \
    -v "$OUTPUT_DIR_ABS:/var/lib/mysql" \
    partnersinhealth/percona-0.1-4 \
    innobackupex --copy-back --datadir=/var/lib/mysql /opt/backup >&2

echo "$OUTPUT_DIR_ABS"
