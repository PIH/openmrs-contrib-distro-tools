#!/bin/bash
# Uploads the complete runs in the backups volume that aren't uploaded yet, oldest first, then cleans
# up (docs/backups.md). Exits non-zero if any run couldn't be uploaded and verified; the next scheduled
# run tries again.
#   BACKUP_UPLOAD   where runs go: empty does nothing (runs stay in the volume); azure (upload-azure.sh)
# Each destination is a script upload-<name>.sh next to this one, sourced here, that defines:
#   upload_check         prints why the destination's settings can't work, or nothing
#   upload_run <run>     copies the run, and returns 0 only when the destination has every file of it
#                        at its local size; else sets `error` and returns non-zero
# Only after upload_run succeeds is the empty file .uploaded/<run> written: cleanup and list-backups
# read only that. A destination never prints its secrets.
set -uo pipefail
HERE=$(dirname "${BASH_SOURCE[0]}")
source "$HERE/lib.sh"

[ -n "${BACKUP_UPLOAD:-}" ] || exit 0

# One upload at a time (the schedule never overlaps itself, but a manual run could). The one that
# waits exits non-zero: it uploaded nothing, so `upload-backups` mustn't look like it succeeded.
exec 8> "$BACKUPS_DIR/.upload.lock"
flock -n 8 || { echo "error: another upload is running; this one did nothing" >&2; exit 1; }

attempt=$(now_iso)
abort() { # <reason>
    status_set upload last_attempt "$attempt" 2>/dev/null
    status_set upload last_result failed 2>/dev/null
    status_set upload last_error "$1" 2>/dev/null
    echo "error: upload failed: $1" >&2
    exit 1
}
destination="$HERE/upload-$BACKUP_UPLOAD.sh"
if [[ ! "$BACKUP_UPLOAD" =~ ^[a-z0-9-]+$ ]] || [ ! -f "$destination" ]; then
    abort "BACKUP_UPLOAD is '$BACKUP_UPLOAD': it must be empty (no uploads) or azure"
fi
error=$(prefix_error); [ -z "$error" ] || abort "$error"
mkdir -p "$UPLOADED_DIR" || abort "couldn't create $UPLOADED_DIR"
# shellcheck source=upload-azure.sh
source "$destination"
error=$(upload_check); [ -z "$error" ] || abort "$error"

errors=()
while read -r run; do
    [ -n "$run" ] || continue
    [ -e "$UPLOADED_DIR/$run" ] && continue
    error=
    log "upload: $run"
    if upload_run "$run"; then
        touch "$UPLOADED_DIR/$run"
        log "upload: $run done"
    else
        errors+=("$error"); log "error: $error"
    fi
done < <(complete_runs)

pending_runs=0 pending_bytes=0
while read -r run; do
    [ -n "$run" ] || continue
    [ -e "$UPLOADED_DIR/$run" ] && continue
    pending_runs=$((pending_runs + 1))
    pending_bytes=$((pending_bytes + $(du -sb "$BACKUPS_DIR/$run" | cut -f1)))
done < <(complete_runs)

if [ ${#errors[@]} -eq 0 ]; then result=success; else result=failed; fi
error=$(printf '%s; ' ${errors[@]+"${errors[@]}"}); error=${error%; }
status_set upload last_attempt "$attempt"
status_set upload last_result "$result"
status_set upload last_error "$error"
status_set --json upload pending_runs "$pending_runs"
status_set --json upload pending_bytes "$pending_bytes"
if [ "$result" = success ]; then status_set upload last_success "$(now_iso)"; fi

"$HERE/cleanup.sh" --uploaded || log "warning: cleanup failed"
if [ "$result" = failed ]; then echo "error: upload failed: $error" >&2; exit 1; fi
