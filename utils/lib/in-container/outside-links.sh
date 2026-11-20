#!/bin/sh
# Prints "path -> target" for each symbolic link under <dir> that points outside it (absolute, or
# climbing above it with ..). Used by backup-openmrs-data-directory (mounted into its alpine run)
# and by the in-container backup scripts. POSIX sh.
# Usage: outside-links.sh <dir> [left-out path...]
# Paths are relative to <dir>, as find prints them. Left-out directories are skipped whole. A link's
# target is judged by its text alone, from the link's directory (so one dangling is fine; one reaching
# .. through another link is judged as written).
set -eu
cd "$1" || exit 1
shift
for d in "$@"; do set -- "$@" -path "./$d" -prune -o; shift; done
find . "$@" -type l -exec sh -c 'for l; do printf "%s\t%s\n" "${l#./}" "$(readlink "$l")"; done' sh {} + |
    awk -F "\t" '{
        out = (substr($2, 1, 1) == "/")
        depth = split($1, parts, "/") - 1
        n = split($2, parts, "/")
        for (i = 1; i <= n && !out; i++)
            if (parts[i] == "..") out = (--depth < 0)
            else if (parts[i] != "." && parts[i] != "") depth++
        if (out) print $1 " -> " $2
    }'
