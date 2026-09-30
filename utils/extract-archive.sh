#!/bin/bash
# General-purpose: extracts a recognized archive. Usage:
#   utils/extract-archive.sh --path=<path> [--output-dir=<dir>]
#
# If <path> is a recognized archive (.7z, .zip, .tar.gz, .tgz, .tar), extracts it into
# --output-dir (default: a fresh directory from mktemp -d) and prints the path to its single
# top-level entry -- or, for an archive with more than one (a "flat" archive, e.g. a legacy
# percona.7z with the backup's files at its top level), the directory it was extracted into.
# Otherwise prints <path> unchanged. Refuses before extracting if the output's filesystem clearly
# hasn't room for the archive's contents (utils/lib/disk-space.sh; SKIP_DISK_SPACE_CHECK=true). ARCHIVE_PASSWORD (env var, optional,
# .7z/.zip only -- a secret) is used if set; extraction is attempted with an empty password if
# it's unset, which succeeds for an unprotected archive and fails cleanly (not hangs) if the
# archive actually needed one. Passed to the container as a bare `-e ARCHIVE_PW` (inheriting the
# already-set value from this script's own environment) rather than `-e ARCHIVE_PW=value`, so the
# value itself never appears in `docker`'s argv -- and so never shows up in `ps` output, which
# shows argv but not environment.
set -euo pipefail
# shellcheck source=lib/disk-space.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/disk-space.sh"

SRC=
OUTPUT_DIR=
for arg in "$@"; do
    case "$arg" in
        --path=*) SRC="${arg#*=}" ;;
        --output-dir=*) OUTPUT_DIR="${arg#*=}" ;;
        *) echo "unknown argument: $arg" >&2; exit 1 ;;
    esac
done
[ -z "$SRC" ] && { echo "usage: $0 --path=<path> [--output-dir=<dir>]" >&2; exit 1; }
[ -e "$SRC" ] || { echo "error: no such file or directory: $SRC" >&2; exit 1; }

case "$SRC" in
    *.7z|*.zip|*.tar.gz|*.tgz|*.tar)
        disk_space_require "extracting $SRC" "$(disk_space_contents_size "$SRC")" \
            "$(disk_space_free_at "${OUTPUT_DIR:-${TMPDIR:-/tmp}}")" "the filesystem of ${OUTPUT_DIR:-${TMPDIR:-/tmp}}"
        ;;
esac

case "$SRC" in
    *.7z|*.zip)
        [ -z "$OUTPUT_DIR" ] && OUTPUT_DIR=$(mktemp -d)
        mkdir -p "$OUTPUT_DIR"
        # Absolute, or `docker run -v` would read a bare relative name as a named volume.
        OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)
        DIR=$(cd "$(dirname "$SRC")" && pwd)
        # Password (if any) and filename are passed as container environment variables rather
        # than interpolated into the `sh -c` string, so neither can be re-parsed as shell
        # syntax. `-p` is always given (even with an empty value) so 7z never falls back to an
        # interactive password prompt, which would hang a non-interactive script -- an empty
        # password succeeds against an unprotected archive and fails cleanly (not hangs)
        # against a genuinely protected one with none given.
        ARCHIVE_PW="${ARCHIVE_PASSWORD:-}" docker run --rm \
            -e ARCHIVE_PW -e ARCHIVE_SRC="$(basename "$SRC")" \
            -v "$DIR:/archive:ro" \
            -v "$OUTPUT_DIR:/out" \
            partnersinhealth/p7zip \
            sh -c '7z x -p"$ARCHIVE_PW" -o/out -y "/archive/$ARCHIVE_SRC"' >&2
        ;;
    *.tar.gz|*.tgz|*.tar)
        [ -z "$OUTPUT_DIR" ] && OUTPUT_DIR=$(mktemp -d)
        mkdir -p "$OUTPUT_DIR"
        OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)
        DIR=$(cd "$(dirname "$SRC")" && pwd)
        docker run --rm \
            -e ARCHIVE_SRC="$(basename "$SRC")" \
            -v "$DIR:/archive:ro" \
            -v "$OUTPUT_DIR:/out" \
            alpine:3.21 \
            sh -c 'case "$ARCHIVE_SRC" in *.tar) tar xf "/archive/$ARCHIVE_SRC" -C /out ;; *) tar xzf "/archive/$ARCHIVE_SRC" -C /out ;; esac' >&2
        ;;
    *)
        echo "$SRC"
        exit 0
        ;;
esac

EXTRACTED=$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1)
[ -z "$EXTRACTED" ] && { echo "error: extraction of $SRC produced no files" >&2; exit 1; }
# Always a single path, since callers capture this command's stdout as one: the one top-level entry
# (a dump file, or an archive's own folder), or else the directory holding them all.
if [ "$(echo "$EXTRACTED" | wc -l)" -eq 1 ]; then
    echo "$EXTRACTED"
else
    echo "$OUTPUT_DIR"
fi
