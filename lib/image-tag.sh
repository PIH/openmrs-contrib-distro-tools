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

# macOS has shasum, not sha256sum.
if command -v sha256sum >/dev/null 2>&1; then
    sha256() { sha256sum | cut -c1-64; }
else
    sha256() { shasum -a 256 | cut -c1-64; }
fi

cd "$1"
find . -type f | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r path; do
    printf '%s  %s\n' "$(sha256 < "$path")" "$path"
done | sha256 | cut -c1-12
