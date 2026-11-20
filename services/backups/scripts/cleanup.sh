#!/bin/bash
# Deletes old runs from the backups volume. Only complete runs count as backups.
# Usage: cleanup.sh --local-only | --uploaded
#   --local-only  no uploads: keeps the newest BACKUP_KEEP_LOCAL complete runs
#   --uploaded    uploads configured: deletes complete runs that are uploaded, except the newest
#                 BACKUP_KEEP_LOCAL complete ones; one not uploaded is never deleted
# Both also delete .failed and .partial runs older than the newest complete run (a run in progress is
# always newer). BACKUP_KEEP_LOCAL=all deletes nothing.
# azcopy's logs and job plans (upload-azure.sh) older than 14 days are deleted too (whatever the mode).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

mode=${1:-}
case "$mode" in --local-only|--uploaded) ;; *) echo "usage: cleanup.sh --local-only | --uploaded" >&2; exit 2 ;; esac
# A job still running touches its plan and log, so only abandoned ones age out.
if [ -d "$AZCOPY_DIR" ]; then find "$AZCOPY_DIR" -type f -mtime +14 -delete; fi
error=$(prefix_error); [ -z "$error" ] || { echo "error: $error" >&2; exit 1; }
keep=${BACKUP_KEEP_LOCAL:-3}
if [ "$keep" = all ]; then log "cleanup: BACKUP_KEEP_LOCAL=all, nothing deleted"; exit 0; fi
[[ "$keep" =~ ^[1-9][0-9]*$ ]] || { echo "error: BACKUP_KEEP_LOCAL must be 1 or more, or all, not '$keep'" >&2; exit 1; }

mapfile -t runs < <(complete_runs)
count=${#runs[@]}
[ "$count" -gt 0 ] || exit 0

delete_run() { # <name>: a folder directly under BACKUPS_DIR
    log "cleanup: deleting $1"
    rm -rf "$BACKUPS_DIR/${1:?}"
    rm -f "$UPLOADED_DIR/$1"
}

for ((i = 0; i < count - keep; i++)); do
    if [ "$mode" = --uploaded ] && [ ! -e "$UPLOADED_DIR/${runs[i]}" ]; then continue; fi
    delete_run "${runs[i]}"
done

newest=${runs[count - 1]}
for d in "$BACKUPS_DIR/$BACKUP_PREFIX"_*.failed/ "$BACKUPS_DIR/$BACKUP_PREFIX"_*.partial/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    if [[ "$name" < "$newest" ]]; then delete_run "$name"; fi
done
