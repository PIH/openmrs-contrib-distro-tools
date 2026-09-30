#!/bin/bash
# Extracts an archive and prints where its contents are: the path of its single top-level entry,
# or, for an archive with several (e.g. a legacy percona.7z), the directory it extracted into.
# Prints --path unchanged if it isn't an archive.
#
# Usage: openmrs-utils extract-archive --path=<path> [--output-dir=<dir>]
#   --path            a .7z, .zip, .tar.gz, .tgz or .tar archive
#   --output-dir      where to extract it (default: a new temporary directory)
#   ARCHIVE_PASSWORD  for a protected .7z or .zip (without it, one fails cleanly)
#   SKIP_DISK_SPACE_CHECK=true  skips the free-space check
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/disk-space.sh
. "$UTILS_DIR/lib/disk-space.sh"

SRC=
OUTPUT_DIR=
for arg in "$@"; do
    case "$arg" in
        --path=*) SRC="${arg#*=}" ;;
        --output-dir=*) OUTPUT_DIR="${arg#*=}" ;;
        *) die "unknown argument: $arg" ;;
    esac
done
[ -n "$SRC" ] || usage
[ -e "$SRC" ] || die "no such file or directory: $SRC"
case "$SRC" in
    *.7z|*.zip|*.tar.gz|*.tgz|*.tar) ;;
    *) echo "$SRC"; exit 0 ;;
esac

WHERE=${OUTPUT_DIR:-${TMPDIR:-/tmp}}
disk_space_require "extracting $SRC" "$(disk_space_contents_size "$SRC")" \
    "$(disk_space_free_at "$WHERE")" "the filesystem of $WHERE"
OUTPUT_DIR=${OUTPUT_DIR:-$(mktemp -d)}
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)

docker run --rm -e ARCHIVE_PASSWORD \
    -v "$(cd "$(dirname "$SRC")" && pwd):/archive:ro" -v "$OUTPUT_DIR:/out" \
    -v "$UTILS_DIR/lib/in-container/extract.sh:/extract.sh:ro" "$P7ZIP_IMAGE" \
    sh /extract.sh "/archive/$(basename "$SRC")" /out >&2

# One path, whatever the archive holds, since callers capture it.
EXTRACTED=$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1)
[ -n "$EXTRACTED" ] || die "extraction of $SRC produced no files"
if [ "$(wc -l <<< "$EXTRACTED")" -eq 1 ]; then echo "$EXTRACTED"; else echo "$OUTPUT_DIR"; fi
