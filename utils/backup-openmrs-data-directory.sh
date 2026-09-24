#!/bin/bash
# General-purpose: archives an OpenMRS application data directory (an openmrs-data volume, or a
# host directory) into a local archive, directly usable as `openmrs-docker <name> initialize`'s
# RESTORE_OPENMRS_DATA_PATH. Usage:
#   utils/backup-openmrs-data-directory.sh --volume=<openmrs-data volume or host dir> --output=<path>
#       [--exclude-distribution-artifacts] [--allow-running]
#
# --volume is either a named Docker volume (validated via `docker volume inspect` -- `docker run -v`
# would otherwise silently create a new, empty volume of that name and back that up instead) or an
# absolute host directory path.
#
# --output must end in .tar.gz/.tgz (plain, gzip-compressed tar) or .7z (password-protected
# archive, matching PIH's existing backup convention -- ARCHIVE_PASSWORD env var, required). Either
# way the archive contains a single top-level directory named after the archive itself (e.g.
# malawi-data.tar.gz and malawi-data.7z both contain malawi-data/) -- initialize unwraps it
# when restoring the archive directly, and `utils/extract-archive.sh --path=<output>` prints
# exactly that directory's path, for anything wanting a plain directory instead. A failed backup
# never leaves a partial file behind.
#
# Unlike tar, 7z doesn't record file ownership -- a restore from .7z yields files owned by
# whoever extracted them. Irrelevant to restore-openmrs-data-volume-from-backup.yaml (which
# never chowns either way), but use .tar.gz if ownership matters elsewhere.
#
# By default the whole directory is backed up, same as the seed image build
# (.github/workflows/build-seeded-image.yml). --exclude-distribution-artifacts skips the contents
# of modules/, owa/, configuration/ and frontend/ (keeping the empty directories), and the
# .openmrs-lib-cache directory OpenMRS rebuilds from modules/: the openmrs-core
# image's startup-init.sh re-copies all four from the image's own /openmrs/distribution on every
# start, so they're not state. Excluding them also avoids restoring stale artifacts onto a
# different distro version -- startup-init.sh's attempt to clear them first
# (`rm -fR "${OMRS_MODULES_DIR:?}/*"`) quotes the glob, so it never actually deletes anything, and
# an old .omod whose filename differs from its replacement would survive alongside it.
#
# Refuses to run while any running container has --volume mounted (named volume or host
# directory), since that can capture files mid-write (e.g. the search index) -- the seed image
# build likewise stops OpenMRS before exporting. --allow-running overrides this, e.g. for a
# production server that can't be taken down, at the cost of a possibly inconsistent copy.
set -euo pipefail

VOLUME=
OUTPUT_PATH=
EXCLUDE_DISTRIBUTION_ARTIFACTS=false
ALLOW_RUNNING=false
for arg in "$@"; do
    case "$arg" in
        --volume=*) VOLUME="${arg#*=}" ;;
        --output=*) OUTPUT_PATH="${arg#*=}" ;;
        --exclude-distribution-artifacts) EXCLUDE_DISTRIBUTION_ARTIFACTS=true ;;
        --allow-running) ALLOW_RUNNING=true ;;
        *) echo "unknown argument: $arg" >&2; exit 1 ;;
    esac
done
usage() { echo "usage: $0 --volume=<openmrs-data volume or host dir> --output=<path.tar.gz|path.tgz|path.7z> [--exclude-distribution-artifacts] [--allow-running]" >&2; exit 1; }
[ -z "$VOLUME" ] && usage
[ -z "$OUTPUT_PATH" ] && usage
case "$OUTPUT_PATH" in
    *.tar.gz|*.tgz|*.7z) ;;
    *) echo "error: --output must end in .tar.gz, .tgz or .7z" >&2; exit 1 ;;
esac
case "$OUTPUT_PATH" in
    *.7z) [ -z "${ARCHIVE_PASSWORD:-}" ] && { echo "error: ARCHIVE_PASSWORD must be set to produce a .7z output" >&2; exit 1; } ;;
esac

case "$VOLUME" in
    /*) [ -d "$VOLUME" ] || { echo "error: no such directory: $VOLUME" >&2; exit 1; } ;;
    *) docker volume inspect "$VOLUME" >/dev/null 2>&1 || { echo "error: no such volume: $VOLUME" >&2; exit 1; } ;;
esac

case "$OUTPUT_PATH" in
    /*) ;;
    *) OUTPUT_PATH="$(pwd)/$OUTPUT_PATH" ;;
esac
[ -e "$OUTPUT_PATH" ] && { echo "error: $OUTPUT_PATH already exists" >&2; exit 1; }

RUNNING=$(docker ps --filter "volume=$VOLUME" -q)
if [ -n "$RUNNING" ]; then
    if $ALLOW_RUNNING; then
        echo "warning: $VOLUME is in use by a running container -- the backup may not be consistent." >&2
    else
        echo "error: $VOLUME is in use by a running container -- stop it first, or pass --allow-running to back up anyway." >&2
        exit 1
    fi
fi

OUTPUT_NAME=$(basename "$OUTPUT_PATH")
TOP_DIR="${OUTPUT_NAME%.tar.gz}"
TOP_DIR="${TOP_DIR%.tgz}"
TOP_DIR="${TOP_DIR%.7z}"

# Contents only (the trailing /*), so the directories themselves are still restored, empty.
EXCLUDES=()
if $EXCLUDE_DISTRIBUTION_ARTIFACTS; then
    for dir in modules owa configuration frontend; do
        EXCLUDES+=("$TOP_DIR/$dir/*")
    done
    # Module classes OpenMRS unpacks from modules/ on startup and rebuilds when missing.
    EXCLUDES+=("$TOP_DIR/.openmrs-lib-cache")
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"

# A failed archive leaves nothing but a half-written file that looks like a valid backup --
# clean it up on any error.
trap 'rm -f "$OUTPUT_PATH"' ERR

echo "Backing up $VOLUME to $OUTPUT_PATH..." >&2
# Mounted read-only at /backup/$TOP_DIR, and archived relative to /backup, so that name becomes the
# archive's single top-level entry -- under /backup rather than at / so an archive named e.g.
# etc.tar.gz can't mount over the container's own /etc.
case "$OUTPUT_PATH" in
    *.7z)
        # 7z can't write a .7z to stdout, so it's written inside the container (as root) and then
        # handed back to whoever's running this script.
        ARCHIVE_PW="$ARCHIVE_PASSWORD" docker run --rm \
            -e ARCHIVE_PW -e OUT_NAME="$OUTPUT_NAME" -e TOP_DIR="$TOP_DIR" -e OWNER="$(id -u):$(id -g)" \
            -v "$VOLUME:/backup/$TOP_DIR:ro" \
            -v "$(dirname "$OUTPUT_PATH"):/out" \
            -w /backup \
            partnersinhealth/p7zip \
            sh -c '7z a -p"$ARCHIVE_PW" -mx5 -t7z "/out/$OUT_NAME" "$TOP_DIR" "$@" && chown "$OWNER" "/out/$OUT_NAME"' \
            sh ${EXCLUDES[@]+"${EXCLUDES[@]/#/-x!}"} >&2
        ;;
    *)
        docker run --rm -v "$VOLUME:/backup/$TOP_DIR:ro" alpine:3.21 \
            tar czf - -C /backup ${EXCLUDES[@]+"${EXCLUDES[@]/#/--exclude=}"} "$TOP_DIR" > "$OUTPUT_PATH"
        ;;
esac
echo "Backed up $VOLUME to $OUTPUT_PATH." >&2
