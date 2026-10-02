# Commands that run, stop and inspect an instance's containers. Sourced by openmrs-docker.

cmd_start() {
    if $DEV || $BUILD; then require_distro_source; fi
    warn_on_drift
    if $BUILD; then build_image; fi
    start_stack
}

cmd_update() {
    if $DEV || $BUILD; then require_distro_source; fi
    warn_on_drift
    if $BUILD; then build_image; fi
    compose pull
    start_stack
}

cmd_stop() { compose down --remove-orphans; }
cmd_restart() { compose restart; }
cmd_build() { build_image; }
cmd_pull() { compose pull; }

cmd_status() {
    local holder
    compose ps
    holder=$(lock_holder)
    [ -z "$holder" ] || echo "Busy: $holder"
}

cmd_logs() { # [svc]
    compose logs -f "$@"
}

cmd_run_service() { # [--pull] <svc> [command...]
    local pull=false svc
    if [ "${1:-}" = --pull ]; then pull=true; shift; fi
    svc=$1
    shift
    [ -e "$INSTANCE_DIR/$svc.yaml" ] || die "$svc not present on $NAME (run 'add-service $svc' first)"
    # Named explicitly, so a profiled service's image is pulled too (a plain `pull` skips them).
    if $pull; then compose pull "$svc"; fi
    if [ "$(service_directive "$svc" run-service)" != holds-lock ]; then
        compose run --rm "$svc" "$@"
        return
    fi
    # A lock-holding service (petl) is a job against the running instance: its setups run first, as
    # one-off containers with the current env, so it never runs on a failed one, and neither they
    # nor it start, stop or recreate any of the instance's containers (--no-deps).
    local setup
    for setup in $(setup_services); do
        compose run --rm --no-deps "$setup" || die "$setup failed (above), so $svc didn't run -- is $NAME running ('$0 $NAME start')?"
    done
    compose run --rm --no-deps "$svc" "$@"
}

cmd_wait() {
    local container="${SERVICE_NAME}-openmrs" logs_pid
    # From now: a container that has run for a while has a long history, which isn't this startup.
    docker logs -f --since "$(date +%s)" "$container" 2>&1 &
    logs_pid=$!
    # OpenMRS's healthcheck (/openmrs/health/started) turns unhealthy only once it has failed to
    # start, unlike MySQL's during an import, so that fails at once.
    if "$TOOL_DIR/utils/wait-for-healthy.sh" --container="$container" --timeout=3600 --fail-on-unhealthy=true; then
        kill "$logs_pid" 2>/dev/null || true
        echo "OpenMRS is ready."
    else
        kill "$logs_pid" 2>/dev/null || true
        die "OpenMRS did not become ready -- see the log output above, or '$0 $NAME logs openmrs'."
    fi
}
