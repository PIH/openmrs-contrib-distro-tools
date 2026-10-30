#!/bin/sh
# Usage: openmrs-utils hash-directory <dir>
# Prints a short content hash of a directory: the first 12 hex of the sha256 of
# "<sha256>  <path>\n" for every file under <dir>, sorted by LC_ALL=C relative path. Only content and
# paths count (not mtimes or creation order), so it comes out the same on every checkout.
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
# read must fail the script rather than print a hash that matches nothing.
files=$(find . -type f) || { echo "error: can't list $1" >&2; exit 1; }
[ -n "$files" ] || { echo "error: no files in $1" >&2; exit 1; }
listing=$(printf '%s\n' "$files" | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r path; do
    hash=$(sha256 < "$path") || { echo "error: can't read $1/$path" >&2; exit 1; }
    [ -n "$hash" ] || { echo "error: no hash for $1/$path" >&2; exit 1; }
    printf '%s  %s\n' "$hash" "$path"
done) || exit 1
hash=$(printf '%s\n' "$listing" | sha256)
# An empty or odd hash (a broken sha256sum) must fail, not be printed.
case $hash in
    '' | *[!0-9a-f]*) echo "error: couldn't hash $1" >&2; exit 1 ;;
esac
echo "$hash" | cut -c1-12
