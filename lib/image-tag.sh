#!/bin/sh
# Usage: lib/image-tag.sh <dir>
# Prints the content-hash tag of an image's folder: the first 12 hex of the sha256 of
# "<sha256>  <path>\n" for every file under <dir>, sorted by LC_ALL=C relative path. Only content and
# paths count (not mtimes or creation order), so CI and every checkout compute the same tag.
set -eu

if [ $# -ne 1 ] || [ ! -d "$1" ]; then
    echo "usage: $0 <dir>" >&2
    echo "error: not a directory: ${1-}" >&2
    exit 2
fi

# The hash of stdin. macOS has shasum, not sha256sum. No pipe, so a read error is a failure.
sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sum=$(sha256sum); else sum=$(shasum -a 256); fi
    echo "${sum%% *}"
}

cd "$1"
# Each step on its own, not one pipeline: sh has no pipefail, and a file that can't be listed or
# read must fail the script rather than leave a tag that matches nothing.
files=$(find . -type f) || { echo "error: can't list $1" >&2; exit 1; }
[ -n "$files" ] || { echo "error: no files in $1" >&2; exit 1; }
listing=$(printf '%s\n' "$files" | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r path; do
    hash=$(sha256 < "$path") || { echo "error: can't read $1/$path" >&2; exit 1; }
    printf '%s  %s\n' "$hash" "$path"
done) || exit 1
tag=$(printf '%s\n' "$listing" | sha256)
echo "$tag" | cut -c1-12
