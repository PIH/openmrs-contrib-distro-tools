#!/bin/sh
# Runs inside P7ZIP_IMAGE (7-Zip and busybox tar): extracts an archive, or copies a directory, into
# <dir>, which is created if needed. Used by utils/extract-archive.sh and initialize's restore
# overlays.
#
# Usage: extract.sh <archive or directory> <dir> [--print-root]
#   <archive>     .7z or .zip (with ARCHIVE_PASSWORD, if set, on 7z's stdin), .tar.gz, .tgz or .tar
#   --print-root  prints where the contents are: the single top-level folder, if that's all there
#                 is (as backup-openmrs-data-directory makes), otherwise <dir>
set -eu
src=$1 dir=$2
mkdir -p "$dir"
case "$src" in
    *.7z|*.zip) printf '%s\n' "${ARCHIVE_PASSWORD:-}" | 7z x -o"$dir" -y "$src" >/dev/null ;;
    # z given explicitly: busybox tar's own gzip detection fails on long runs of zeros, which InnoDB
    # files are full of ("invalid tar header checksum").
    *.tar.gz|*.tgz) tar xzf "$src" -C "$dir" ;;
    *.tar) tar xf "$src" -C "$dir" ;;
    *)
        [ -d "$src" ] || { echo "error: not an archive or a directory: $src" >&2; exit 1; }
        cp -a "$src/." "$dir/"
        ;;
esac
if [ "${3:-}" = --print-root ]; then
    top=$(find "$dir" -mindepth 1 -maxdepth 1)
    if [ -n "$top" ] && [ "$(echo "$top" | wc -l)" -eq 1 ] && [ -d "$top" ]; then echo "$top"; else echo "$dir"; fi
fi
