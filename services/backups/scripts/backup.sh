#!/bin/bash
# One backup run of the instance's services into the backups volume (docs/backups.md):
# <prefix>_<UTC timestamp>.partial/, every service's script writing into it, then renamed to the
# complete name, or <run>.failed when any script failed (the others still run) or none wrote a file. A
# failed run keeps only its backup.log (the volume shares the disk with the database). Exits non-zero
# on failure.
#   BACKUP_ARCHIVE_PASSWORD   required; reaches each script as ARCHIVE_PASSWORD
#   BACKUP_PLAN               <svc>=script|none|unset for each of the instance's services, in order:
#                             script runs BACKUP_SERVICES_DIR/<svc>.sh; none has nothing to back up;
#                             unset is recorded as not backed up
#   BACKUP_SERVICES_DIR       default /opt/backup/services
#   BACKUP_MIN_FREE           free space left after the run: bytes, or with a K, M or G suffix (default 2G)
#   BACKUP_KEEP_LOCAL, BACKUP_UPLOAD  with no upload destination, cleanup runs at the end (cleanup.sh --local-only)
# One run at a time (/backups/.backup.lock): a run that starts while another is going exits at once
# with an error line, leaving status.json to the run in progress. Cleanup relies on this: a .partial
# run it finds is stale, never one in progress.
set -uo pipefail
HERE=$(dirname "${BASH_SOURCE[0]}")
source "$HERE/lib.sh"

# Held until the script exits (the service scripts inherit it, so it outlasts a stray child too).
exec 8> "$BACKUPS_DIR/.backup.lock" || { echo "error: backup failed: couldn't open $BACKUPS_DIR/.backup.lock" >&2; exit 1; }
if ! flock -n 8; then
    echo "error: backup not started: another backup is running in $BACKUPS_DIR" >&2
    exit 1
fi

attempt=$(now_iso)
# An attempt that can't even start is still recorded, so monitoring sees it (status.json is at the
# volume's root, needing neither the prefix nor a run folder).
abort() { # <reason>
    status_set backup last_attempt "$attempt" 2>/dev/null
    status_set backup last_result failed 2>/dev/null
    status_set backup last_error "$1" 2>/dev/null
    echo "error: backup failed: $1" >&2
    exit 1
}

if [ -z "${BACKUP_ARCHIVE_PASSWORD:-}" ]; then abort "BACKUP_ARCHIVE_PASSWORD must be set"; fi
error=$(prefix_error); [ -z "$error" ] || abort "$error"
if [ -z "${BACKUP_PLAN:-}" ]; then abort "BACKUP_PLAN is empty: pihx sets it from the instance's services"; fi
SERVICES_DIR="${BACKUP_SERVICES_DIR:-/opt/backup/services}"
MIN_RUN_BYTES=$((1024 * 1024 * 1024))
min_free=${BACKUP_MIN_FREE:-2G}
case "$min_free" in
    *[0-9]K) mult=1024 ;; *[0-9]M) mult=$((1024 ** 2)) ;; *[0-9]G) mult=$((1024 ** 3)) ;; *) mult=1 ;;
esac
digits=${min_free%[KMG]}
[[ "$digits" =~ ^[0-9]{1,12}$ ]] || abort "BACKUP_MIN_FREE must be a byte count, or one with a K, M or G suffix, not '$min_free'"
MIN_FREE_BYTES=$((10#$digits * mult))

run=$(run_name)
RUN_DIR="$BACKUPS_DIR/$run.partial"
failures=()
not_backed_up=()

# Free space needed: the size of the newest complete run (1 GiB with none), plus BACKUP_MIN_FREE left
# over, so backups stop before they fill the disk.
size=$MIN_RUN_BYTES
newest=$(complete_runs | tail -n 1)
if [ -n "$newest" ]; then size=$(du -sb "$BACKUPS_DIR/$newest" | cut -f1); fi
free=$(df -PB1 "$BACKUPS_DIR" | awk 'NR == 2 { print $4 }')
if ! [[ "$size" =~ ^[0-9]+$ && "$free" =~ ^[0-9]+$ ]]; then
    abort "couldn't determine the free space in $BACKUPS_DIR or the size of the newest run"
fi
needed=$((size + MIN_FREE_BYTES))

mkdir "$RUN_DIR" || abort "couldn't create $RUN_DIR"
RUN_LOG="$RUN_DIR/backup.log"
export RUN_LOG
log "backup $run started"

if [ "$free" -lt "$needed" ]; then
    failures+=("not enough free space in $BACKUPS_DIR: $free bytes free, $needed needed (the newest run, plus BACKUP_MIN_FREE)")
    log "error: ${failures[0]}"
else
    export BACKUP_RUN_DIR="$RUN_DIR" ARCHIVE_PASSWORD="$BACKUP_ARCHIVE_PASSWORD"
    for entry in $BACKUP_PLAN; do
        svc=${entry%%=*}
        kind=${entry#*=}
        case "$kind" in
            none)
                log "$svc: nothing to back up"
                continue ;;
            unset)
                log "$svc: not backed up (it has no backup script)"
                not_backed_up+=("$svc")
                continue ;;
            script) ;;
            *)
                failures+=("$svc: unknown backup kind '$kind' in BACKUP_PLAN")
                log "error: ${failures[-1]}"
                continue ;;
        esac
        script="$SERVICES_DIR/$svc.sh"
        if [ ! -f "$script" ]; then
            failures+=("$svc: its backup script isn't mounted at $script (services/$svc/with-backups.yaml)")
            log "error: ${failures[-1]}"
            continue
        fi
        log "$svc: backing up"
        # stdout joins stderr: a script's output all goes to the container log and backup.log.
        bash "$script" 2>&1 >&2 | tee -a "$RUN_LOG" >&2
        code=${PIPESTATUS[0]}
        if [ "$code" -eq 0 ]; then
            log "$svc: done"
        else
            log "error: $svc failed (exit $code)"
            failures+=("$svc failed (exit $code)")
        fi
    done
fi

if [ ${#failures[@]} -eq 0 ] && [ -z "$(find "$RUN_DIR" -mindepth 1 ! -name backup.log -print -quit)" ]; then
    failures+=("no service wrote a backup")
    log "error: ${failures[-1]}"
fi
if [ ${#failures[@]} -eq 0 ]; then
    result=success final=$run
else
    result=failed final=$run.failed
    # Archives (whole or partial) of a failed run aren't backups; a run failing nightly mustn't fill the disk.
    find "$RUN_DIR" -mindepth 1 -maxdepth 1 ! -name backup.log -exec rm -rf {} +
fi
log "backup $run $result"
mv "$RUN_DIR" "$BACKUPS_DIR/$final"
RUN_LOG="$BACKUPS_DIR/$final/backup.log"

error=$(printf '%s; ' ${failures[@]+"${failures[@]}"}); error=${error%; }
nbu=$(jq -cn '$ARGS.positional' --args ${not_backed_up[@]+"${not_backed_up[@]}"})
status_set backup last_attempt "$attempt"
status_set backup last_result "$result"
status_set backup last_error "$error"
status_set backup last_run "$final"
status_set --json backup not_backed_up "$nbu"
if [ "$result" = success ]; then status_set backup last_success "$(now_iso)"; fi

if [ -z "${BACKUP_UPLOAD:-}" ]; then "$HERE/cleanup.sh" --local-only || log "warning: cleanup failed"; fi
if [ "$result" = failed ]; then
    # Plain, and last, so it's the line a reader of the output or backup.log sees.
    echo "error: backup $run failed: $error" | tee -a "$RUN_LOG" >&2
    exit 1
fi
