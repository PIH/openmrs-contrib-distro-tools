# Shared by the backup jobs (backup.sh, upload.sh, cleanup.sh). Sourced, not run.
# shellcheck shell=bash disable=SC2034
#   BACKUPS_DIR      the backups volume (default /backups)
#   BACKUP_PREFIX    run folders are <prefix>_<UTC timestamp> (compose.yaml defaults it to the instance's name)
#   RUN_LOG          when set, `log` also appends to this file (the run's backup.log)
BACKUPS_DIR="${BACKUPS_DIR:-/backups}"
STATUS_FILE="$BACKUPS_DIR/status.json"
UPLOADED_DIR="$BACKUPS_DIR/.uploaded"   # one empty file per uploaded run, named after it
AZCOPY_DIR="$BACKUPS_DIR/.azcopy"       # azcopy's logs/ and plans/ (upload.sh), pruned by cleanup.sh

log() { # <message...>
    local line
    line="$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
    printf '%s\n' "$line" >&2
    if [ -n "${RUN_LOG:-}" ]; then printf '%s\n' "$line" >> "$RUN_LOG"; fi
    return 0
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Prints why BACKUP_PREFIX can't name run folders, or nothing when it can.
prefix_error() {
    if [ -z "${BACKUP_PREFIX:-}" ]; then
        echo "BACKUP_PREFIX must be set"
    elif ! [[ "$BACKUP_PREFIX" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        echo "BACKUP_PREFIX must be letters, digits, '.', '_' and '-', starting with a letter or digit, not '$BACKUP_PREFIX'"
    fi
}

# A new run's name: <prefix>_<UTC timestamp>.
run_name() { echo "${BACKUP_PREFIX}_$(date -u +%Y%m%dT%H%M%SZ)"; }

# The names of the complete runs in the volume (<prefix>_<timestamp>, no .partial or .failed), oldest first.
complete_runs() {
    local d name
    for d in "$BACKUPS_DIR/$BACKUP_PREFIX"_*/; do
        [ -d "$d" ] || continue
        name=$(basename "$d")
        [[ "${name#"${BACKUP_PREFIX}_"}" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] && echo "$name"
    done | LC_ALL=C sort
}

# Sets .<section>.<key> in status.json to a string, or with --json to the JSON value given. Under a
# lock and replaced whole, since the backup and upload jobs both write it.
status_set() { # [--json] <section> <key> <value>
    local mode=--arg
    if [ "$1" = --json ]; then mode=--argjson; shift; fi
    (
        flock 9
        [ -s "$STATUS_FILE" ] || echo '{}' > "$STATUS_FILE"
        # Replaced only when jq succeeded: a failed one leaves status.json as it was.
        jq --arg s "$1" --arg k "$2" "$mode" v "$3" '.[$s][$k] = $v' "$STATUS_FILE" > "$STATUS_FILE.tmp" \
            && mv "$STATUS_FILE.tmp" "$STATUS_FILE" || { rm -f "$STATUS_FILE.tmp"; exit 1; }
    ) 9> "$BACKUPS_DIR/.status.lock"
}
