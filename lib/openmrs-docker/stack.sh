# Commands that run, stop and inspect an instance's containers. Sourced by openmrs-docker.

cmd_start() {
    local before
    if $DEV || $BUILD; then require_distro_source; fi
    warn_on_drift
    before=$(instance_images)
    if $BUILD; then build_image; fi
    start_stack
    remove_replaced_images "$before"
}

cmd_update() {
    local before
    if $DEV || $BUILD; then require_distro_source; fi
    warn_on_drift
    before=$(instance_images)
    if $BUILD; then build_image; fi
    compose pull
    start_stack
    remove_replaced_images "$before"
}

# All profiles: a lock-holding service's kept container (run-service) would otherwise outlive the
# network it's attached to, and its next run fail.
cmd_stop() { compose --profile '*' down --remove-orphans; }
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
    # A command of its own (e.g. a shell to look around) runs in a one-off container.
    if [ $# -gt 0 ]; then
        compose run --rm --no-deps "$svc" "$@"
        return
    fi
    # The job's own runs share one kept container, recreated only when its image or config changed
    # and otherwise started again: its log builds up across runs in Docker's log, as a running
    # service's does ('logs <svc>'), and docker inspect shows the last run's exit code and time.
    # start -a streams the run's output, forwards signals, and exits with the run's exit code.
    local before
    before=$(instance_images)
    compose up --no-start --no-deps "$svc"
    remove_replaced_images "$before"
    docker start -a "$(compose ps -aq "$svc")"
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
