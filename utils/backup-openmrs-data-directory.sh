#!/bin/bash
# Archives an OpenMRS data directory into a file usable as `openmrs-docker <name> initialize`'s
# RESTORE_OPENMRS_DATA_PATH. The archive holds one folder named after itself (data.tar.gz and
# data.7z both hold data/), which extract-archive prints the path of.
#
# Usage: openmrs-utils backup-openmrs-data-directory --volume=<volume or dir> --output=<file>
#            [--exclude-distribution-artifacts] [--allow-running]
#   --volume          an openmrs-data volume, or an absolute directory path
#   --output          .tar.gz or .tgz, or .7z (encrypted; unlike tar, it doesn't keep file owners)
#   --exclude-distribution-artifacts
#                     leaves out what the OpenMRS image copies in on every start (the contents of
#                     modules/, owa/, configuration/ and frontend/) and .openmrs-lib-cache, which
#                     it rebuilds: smaller, and no stale .omods restored beside a newer distro's
#   --allow-running   backs up even while a container is using --volume (the copy may then be
#                     inconsistent, e.g. the search index)
#   ARCHIVE_PASSWORD  password for a .7z (required for one)
#   SKIP_DISK_SPACE_CHECK=true  skips the free-space check
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/disk-space.sh
. "$UTILS_DIR/lib/disk-space.sh"
# shellcheck source=lib/archive.sh
. "$UTILS_DIR/lib/archive.sh"

VOLUME=
OUTPUT=
EXCLUDE_DISTRIBUTION_ARTIFACTS=false
ALLOW_RUNNING=false
for arg in "$@"; do
    case "$arg" in
        --volume=*) VOLUME="${arg#*=}" ;;
        --output=*) OUTPUT="${arg#*=}" ;;
        --exclude-distribution-artifacts) EXCLUDE_DISTRIBUTION_ARTIFACTS=true ;;
        --allow-running) ALLOW_RUNNING=true ;;
        *) die "unknown argument: $arg" ;;
    esac
done
[ -n "$VOLUME" ] && [ -n "$OUTPUT" ] || usage
case "$OUTPUT" in
    *.tar.gz|*.tgz) ;;
    *.7z) [ -n "${ARCHIVE_PASSWORD:-}" ] || die "ARCHIVE_PASSWORD must be set to produce a .7z output" ;;
    *) die "--output must end in .tar.gz, .tgz or .7z" ;;
esac
require_volume_or_dir "$VOLUME"
OUTPUT=$(abs_path "$OUTPUT")
[ ! -e "$OUTPUT" ] || die "$OUTPUT already exists"
if in_use "$VOLUME"; then
    $ALLOW_RUNNING || die "$VOLUME is in use by a running container -- stop it first, or pass --allow-running to back up anyway."
    warn "$VOLUME is in use by a running container -- the backup may not be consistent."
fi

TOP=$(basename "$OUTPUT")
TOP=${TOP%.tar.gz} TOP=${TOP%.tgz} TOP=${TOP%.7z}
LEAVE_OUT=()
EXCLUDES=()
if $EXCLUDE_DISTRIBUTION_ARTIFACTS; then
    LEAVE_OUT=(modules owa configuration frontend .openmrs-lib-cache)
    # The four folders' contents only, so they're still restored, empty.
    EXCLUDES=("$TOP/modules/*" "$TOP/owa/*" "$TOP/configuration/*" "$TOP/frontend/*" "$TOP/.openmrs-lib-cache")
fi

# Uncompressed: an openmrs-data directory is mostly already-compressed files (images, PDFs).
disk_space_require "backing up $VOLUME" "$(disk_space_size_of "$VOLUME" ${LEAVE_OUT[@]+"${LEAVE_OUT[@]}"})" \
    "$(disk_space_free_at "$OUTPUT")" "the filesystem of $(dirname "$OUTPUT")"
prepare_output_file "$OUTPUT"

note "Backing up $VOLUME to $OUTPUT..."
case "$OUTPUT" in
    *.7z) archive_7z_create "$OUTPUT" "$VOLUME" "$TOP" ${EXCLUDES[@]+"${EXCLUDES[@]/#/-x!}"} ;;
    *)
        # Under /backup rather than /, so an archive named e.g. etc.tar.gz can't mount over /etc.
        docker run --rm -v "$VOLUME:/backup/$TOP:ro" "$ALPINE_IMAGE" \
            tar czf - -C /backup ${EXCLUDES[@]+"${EXCLUDES[@]/#/--exclude=}"} "$TOP" > "$OUTPUT"
        ;;
esac
note "Backed up $VOLUME to $OUTPUT."
