#!/bin/bash
# General-purpose: extracts a recognized archive. Usage:
#   utils/extract-archive.sh --path=<path> [--output-dir=<dir>]
#
# If <path> is a recognized archive (.7z, .zip, .tar.gz, .tgz, .tar), extracts it into
# --output-dir (default: a fresh directory from mktemp -d) and prints the path to its single
# top-level entry. Otherwise prints <path> unchanged. ARCHIVE_PASSWORD (env var, optional,
# .7z/.zip only -- a secret) is used if set; extraction is attempted with an empty password if
# it's unset, which succeeds for an unprotected archive and fails cleanly (not hangs) if the
# archive actually needed one. Passed to the container as a bare `-e ARCHIVE_PW` (inheriting the
# already-set value from this script's own environment) rather than `-e ARCHIVE_PW=value`, so the
# value itself never appears in `docker`'s argv -- and so never shows up in `ps` output, which
# shows argv but not environment.
set -euo pipefail

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
    *.7z|*.zip)
        [ -z "$OUTPUT_DIR" ] && OUTPUT_DIR=$(mktemp -d)
        mkdir -p "$OUTPUT_DIR"
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
        DIR=$(cd "$(dirname "$SRC")" && pwd)
        docker run --rm \
            -e ARCHIVE_SRC="$(basename "$SRC")" \
            -v "$DIR:/archive:ro" \
            -v "$OUTPUT_DIR:/out" \
            alpine:3.21 \
            sh -c 'tar xf "/archive/$ARCHIVE_SRC" -C /out' >&2
        ;;
    *)
        echo "$SRC"
        exit 0
        ;;
esac

EXTRACTED=$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1)
[ -z "$EXTRACTED" ] && { echo "error: extraction of $SRC produced no files" >&2; exit 1; }
# Exactly one entry: more than one would make the printed path multi-line and corrupt every
# caller that captures this command's stdout as a single path.
COUNT=$(echo "$EXTRACTED" | wc -l)
[ "$COUNT" -eq 1 ] || { echo "error: extraction of $SRC produced $COUNT top-level entries, expected exactly 1" >&2; exit 1; }
echo "$EXTRACTED"
