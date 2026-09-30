# Helpers every utils/ script uses. Sourced, not run.
#
# How the utilities behave (the README's "Utilities" section says the same for users):
#   - Values are --name=value options. Secrets are environment variables: they reach the tools in
#     containers by name (`docker -e VAR`), as MYSQL_PWD or on stdin, never on a command line,
#     which `ps` on the host shows for processes in containers too.
#   - Progress and errors go to stderr; stdout carries only a result a caller may capture.
#   - A backup refuses an existing output, and a failed run removes the output it started.
#   - A script's header comment is its usage text, which `usage` prints.

UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=images.sh
. "$UTILS_DIR/lib/images.sh"

die() { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }
note() { echo "$*" >&2; }

# Prints the running script's header comment (the comment block after its #! line), and exits 1.
usage() {
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0" >&2
    exit 1
}

# <path> made absolute against the current directory. It needn't exist.
abs_path() { case "$1" in /*) echo "$1" ;; *) echo "$PWD/${1#./}" ;; esac; }

# Refuses unless <source> is an existing named volume or, as an absolute path, directory: `docker
# run -v` would otherwise quietly create an empty volume of that name.
require_volume_or_dir() { # <source>
    case "$1" in
        /*) [ -d "$1" ] || die "no such directory: $1" ;;
        *) docker volume inspect "$1" >/dev/null 2>&1 || die "no such volume: $1" ;;
    esac
}

# True if a running container has <volume or dir> mounted.
in_use() { [ -n "$(docker ps -q --filter "volume=$1")" ]; }

refuse_if_in_use() { # <volume or dir> [why]
    ! in_use "$1" || die "$1 is in use by a running container -- stop it first${2:+ ($2)}"
}

# Cleanup when the script exits: on_exit runs <command> however it ends, on_failure only if it
# fails. <command> is a string, as for `trap`; the latest registered runs first.
_CLEANUPS=()
on_exit() {
    _CLEANUPS=("$1" ${_CLEANUPS[@]+"${_CLEANUPS[@]}"})
    trap '_run_cleanups $?' EXIT
}
on_failure() { on_exit "[ \"\$_EXIT_STATUS\" -eq 0 ] || { $1; }"; }
_run_cleanups() {
    _EXIT_STATUS=$1
    local c
    for c in "${_CLEANUPS[@]}"; do eval "$c" >/dev/null 2>&1 || true; done
}

# Readies <absolute path> for a new output file: refuses an existing one, creates its parent
# directory, and removes the file again if the script fails.
prepare_output_file() {
    [ ! -e "$1" ] || die "$1 already exists"
    mkdir -p "$(dirname "$1")"
    on_failure "rm -f $(printf %q "$1")"
}

# The same for a new output directory, which this creates. Emptied in a container on failure,
# since the tools that fill one often write as root.
prepare_output_dir() {
    [ ! -e "$1" ] || die "$1 already exists"
    mkdir -p "$1"
    on_failure "docker run --rm -v $(printf %q "$1"):/t $ALPINE_IMAGE find /t -mindepth 1 -delete; rm -rf $(printf %q "$1")"
}
