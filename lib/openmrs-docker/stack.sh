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

cmd_run_service() { # <svc> [command...]
    local svc=$1
    shift
    [ -e "$INSTANCE_DIR/$svc.yaml" ] || die "$svc not present on $NAME (run 'add-service $svc' first)"
    # A lock-holding run starts only once OpenMRS has finished starting (and its Liquibase updates).
    if [ "$(service_directive "$svc" run-service)" = holds-lock ] && [ -e "$INSTANCE_DIR/openmrs.yaml" ]; then
        cmd_wait
    fi
    compose run --rm "$svc" "$@"
}

cmd_wait() {
    local container="${SERVICE_NAME}-openmrs" logs_pid
    docker logs -f "$container" 2>&1 &
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
