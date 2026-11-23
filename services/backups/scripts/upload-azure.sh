# The azure destination of upload.sh (BACKUP_UPLOAD=azure), with azcopy. Sourced, not run.
# shellcheck shell=bash disable=SC2034  # error is read by upload.sh
#   BACKUP_AZURE_URL, BACKUP_AZURE_PATH, BACKUP_AZURE_SAS   <url>/<path>/<run>/ is where a run goes
# A run counts as uploaded only when Azure lists each of its files with the local size. The SAS token
# is never logged.

upload_check() {
    if [ -z "${BACKUP_AZURE_URL:-}" ]; then echo "BACKUP_AZURE_URL must be set"; return; fi
    if [ -z "${BACKUP_AZURE_SAS:-}" ]; then echo "BACKUP_AZURE_SAS must be set"; return; fi
    mkdir -p "$AZCOPY_LOG_LOCATION" "$AZCOPY_JOB_PLAN_LOCATION" || echo "couldn't create $AZCOPY_DIR"
}

# azcopy's logs and job plans live in the volume, so an interrupted transfer outlives the container.
# Hidden, so no run detection sees them; cleanup.sh prunes them.
export AZCOPY_LOG_LOCATION="$AZCOPY_DIR/logs" AZCOPY_JOB_PLAN_LOCATION="$AZCOPY_DIR/plans"
# azcopy sizes its buffers and concurrency from the host's RAM and CPUs, not the container's memory
# limit (BACKUP_MEMORY_LIMIT), and many parallel transfers only contend on a poor link.
export AZCOPY_BUFFER_GB=0.25 AZCOPY_CONCURRENCY_VALUE=4

base="${BACKUP_AZURE_URL:-}"; base="${base%/}"
if [ -n "${BACKUP_AZURE_PATH:-}" ]; then
    path="${BACKUP_AZURE_PATH#/}"; path="${path%/}"
    base="$base/$path"
fi
sas="${BACKUP_AZURE_SAS:-}"; sas="${sas#\?}"

# Passes text through with anything after a ? in a URL, and the token itself, replaced.
redact() {
    local line
    while IFS= read -r line; do
        [ -z "$sas" ] || line="${line//"$sas"/REDACTED}"
        printf '%s\n' "$line" | sed -E 's/(https?:\/\/[^ "?]*)\?[^ "]*/\1?REDACTED/g'
    done
}

run_files() { # <run>: "<name> <size>" per file, sorted
    (cd "$BACKUPS_DIR/$1" && find . -type f | sed 's|^\./||' | while read -r f; do echo "$f $(stat -c %s "$f")"; done | LC_ALL=C sort)
}

upload_run() { # <run>
    local run=$1 out remote local_files
    # azcopy reads stdin, which here is the list of runs, so it gets /dev/null.
    # --overwrite=false: a retry skips the files already in Azure instead of sending them again (the
    # listing below is what proves they are whole). --from-to and --location say the transfer type
    # outright, rather than leaving azcopy to infer it from the URL.
    if ! out=$(azcopy copy "$BACKUPS_DIR/$run" "$base/?$sas" --recursive --from-to LocalBlob \
        --overwrite=false --log-level=WARNING 2>&1 < /dev/null); then
        printf '%s\n' "$out" | redact >&2
        error="$run: azcopy copy failed"
        return 1
    fi
    printf '%s\n' "$out" | grep -E '^(Final Job Status|Total Number of Bytes Transferred):' | redact \
        | while read -r line; do log "upload: $run: azcopy: $line"; done
    if ! out=$(azcopy list "$base/$run/?$sas" --machine-readable --location Blob 2>&1 < /dev/null); then
        printf '%s\n' "$out" | redact >&2
        error="$run: azcopy list failed"
        return 1
    fi
    remote=$(printf '%s\n' "$out" | sed -nE 's/^(.*); Content Length: ([0-9]+)$/\1 \2/p' | LC_ALL=C sort)
    local_files=$(run_files "$run")
    if [ "$remote" != "$local_files" ]; then
        error="$run: files in Azure don't match the local ones"
        return 1
    fi
}
