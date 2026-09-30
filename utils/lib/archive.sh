# Making and reading 7-Zip archives in P7ZIP_IMAGE, for the utils/ scripts and disk-space.sh.
# Sourced, not run.
#
# The password is ARCHIVE_PASSWORD. It reaches the container by name and 7z on stdin, where 7z reads
# it when it asks for one: a bare -p asks when creating, and reading asks only if the archive is
# protected. archive_7z_from_stdin is the one exception.

# shellcheck source=images.sh
. "$(dirname "${BASH_SOURCE[0]}")/images.sh"

# Writes <output.7z> from <source> (a volume or absolute directory), owned by the caller. With a
# <top>, the archive holds one folder of that name, with the source's contents in it; with <top>
# empty, the contents are at its top level. Further arguments are 7z switches, e.g. -x!<path>.
archive_7z_create() { # <output.7z> <source> <top> [7z switch...]
    local output=$1 source=$2 top=$3 mount=/src entry='*'   # 7z expands '*' itself, dotfiles too
    shift 3
    if [ -n "$top" ]; then mount="/src/$top" entry=$top; fi
    ARCHIVE_PASSWORD="${ARCHIVE_PASSWORD:-}" docker run --rm -e ARCHIVE_PASSWORD \
        -e OUT_NAME="$(basename "$output")" -e OWNER="$(id -u):$(id -g)" -v "$source:$mount:ro" \
        -v "$(dirname "$output"):/out" -w /src "$P7ZIP_IMAGE" \
        sh -c 'printf "%s\n" "$ARCHIVE_PASSWORD" | 7z a -p -mx5 -t7z "/out/$OUT_NAME" "$@" >/dev/null &&
               chown "$OWNER" "/out/$OUT_NAME"' sh "$entry" "$@"
}

# Writes <output.7z> holding stdin as one file, <name>, owned by the caller. With stdin carrying the
# data, the password is on 7z's command line in its container (so `ps` on the host shows it) while
# it runs; writing the data to disk first would instead leave it there unencrypted.
archive_7z_from_stdin() { # <output.7z> <name>
    ARCHIVE_PASSWORD="${ARCHIVE_PASSWORD:-}" docker run -i --rm -e ARCHIVE_PASSWORD \
        -e OUT_NAME="$(basename "$1")" -e NAME="$2" -e OWNER="$(id -u):$(id -g)" -v "$(dirname "$1"):/out" "$P7ZIP_IMAGE" \
        sh -c '7z a -si"$NAME" -p"$ARCHIVE_PASSWORD" -mx5 -t7z "/out/$OUT_NAME" >/dev/null && chown "$OWNER" "/out/$OUT_NAME"'
}

# Prints 7z's technical listing of <archive> (-slt: a "Name = value" line per property per entry).
archive_7z_list() { # <archive>
    ARCHIVE_PASSWORD="${ARCHIVE_PASSWORD:-}" docker run --rm -e ARCHIVE_PASSWORD \
        -e NAME="$(basename "$1")" -v "$(cd "$(dirname "$1")" && pwd):/a:ro" "$P7ZIP_IMAGE" \
        sh -c 'printf "%s\n" "${ARCHIVE_PASSWORD:-}" | 7z l -slt "/a/$NAME"'
}
