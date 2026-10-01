# Running an instance's Compose project, and its lock. Sourced by openmrs-docker.

# COMPOSE_FILES: the instance's env file and fragments, and the dev and build overlays with --dev and
# --build (and for `build`). initialize
# adds its restore overlays, which nothing else uses. Rebuilt after a fragment is added or removed.
compose_files() {
    local f
    COMPOSE_FILES=(--env-file "$ENV_FILE")
    for f in "$INSTANCE_DIR"/*.yaml; do
        [ -e "$f" ] || continue
        COMPOSE_FILES+=(-f "$f")
    done
    if $DEV; then COMPOSE_FILES+=(-f "$MODES_DIR/dev.yaml"); fi
    if $BUILD; then COMPOSE_FILES+=(-f "$MODES_DIR/build.yaml"); fi
}

compose() { docker compose "${COMPOSE_FILES[@]}" "$@"; }

start_stack() { compose up -d; }

require_distro_source() {
    [ -n "${DISTRO_SOURCE_DIR:-}" ] || die "DISTRO_SOURCE_DIR must be set in $ENV_FILE for this command"
}

build_image() {
    require_distro_source
    (cd "$DISTRO_SOURCE_DIR" && mvn clean package -U)
    # Explicitly: for a service with both image: and build:, `up` pulls the named tag if a registry
    # has it, and only builds if that fails, so it would run the published image, not this build.
    compose build
}

# Advisory only: never blocks, prompts or changes anything.
warn_on_drift() {
    local drifted=() f canonical
    for f in "$INSTANCE_DIR"/*.yaml; do
        [ -e "$f" ] || continue
        canonical="$SERVICES_DIR/$(basename "$f")"
        [ -e "$canonical" ] || continue
        cmp -s "$f" "$canonical" || drifted+=("$(basename "$f")")
    done
    if [ ${#drifted[@]} -gt 0 ]; then
        note "Note: newer service definitions available for: ${drifted[*]}"
        note "Run '$0 $NAME sync' to update before the next start/update."
    fi
}

# Volumes initialize's overlays create, which no fragment declares: `down` without -v keeps them,
# and destroy's `down -v` doesn't know them.
remove_restore_volumes() { # <project>
    docker volume rm "$1_db-init" "$1_percona-staging" >/dev/null 2>&1 || true
}

# Commands that change the instance hold its lock until they exit, and refuse while another command
# holds it: puppet runs `pull && start` on every apply, which mustn't happen part way through e.g.
# an initialize or a PETL run. With OPENMRS_DOCKER_LOCK_WAIT=<seconds> they wait that long for it
# instead. flock(1) releases the lock however its holder exits. Without flock (util-linux, so not on
# macOS), commands run unlocked.
lock_instance() { # hold | check (refuse if held, without holding it)
    local lock="$INSTANCE_DIR/.lock"
    command -v flock >/dev/null || return 0
    # Opened read-only (all flock needs), so a lock file another user created still works.
    [ -e "$lock" ] || : >> "$lock"
    exec 9<"$lock"
    local wait=${OPENMRS_DOCKER_LOCK_WAIT:-0}
    [[ "$wait" =~ ^[0-9]+$ ]] || die "OPENMRS_DOCKER_LOCK_WAIT must be a number of seconds"
    if ! flock -n 9; then
        [ "$wait" -gt 0 ] || die "$NAME is busy: $(cat "$lock" 2>/dev/null) -- run this again once that finishes."
        note "$NAME is busy: $(cat "$lock" 2>/dev/null) -- waiting up to ${wait}s"
        flock -w "$wait" 9 || die "$NAME is still busy after ${wait}s: $(cat "$lock" 2>/dev/null)"
    fi
    if [ "$1" = check ]; then
        exec 9>&-
    else
        printf '%s (pid %s, started %s)\n' "$COMMAND" "$$" "$(date '+%Y-%m-%d %H:%M:%S')" 2>/dev/null > "$lock" || true
    fi
}

# The lock's holder, if a command holds it.
lock_holder() {
    local lock="$INSTANCE_DIR/.lock"
    command -v flock >/dev/null && [ -f "$lock" ] || return 0
    ( flock -n 8 ) 8<"$lock" || cat "$lock"
}
