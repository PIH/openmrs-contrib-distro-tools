# shellcheck shell=bash
# Shared by the dhis2 commands (sourced): whether DHIS2 may be mid-migration. Needs SERVICE_NAME.

# What Tomcat logs when DHIS2 fails to deploy (e.g. a failed migration): it keeps running, never healthy.
DEPLOY_FAILED='startup failed due to previous errors'

# Whether dhis2 is running and still starting, without having logged a failed deploy since its
# container started: its migrations may be running, and stopping it would interrupt them. Its
# healthcheck says "starting" for its start_period (2h) and "unhealthy" after it, while a long
# migration may still be running: both count.
dhis2_still_starting() {
    local container="$SERVICE_NAME-dhis2" state started
    state=$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' \
        "$container" 2>/dev/null || true)
    case "$state" in
        "running starting" | "running unhealthy") ;;
        *) return 1 ;;
    esac
    started=$(docker inspect --format '{{.State.StartedAt}}' "$container")
    # Not grep -q: it would end docker logs with SIGPIPE, failing the pipeline (pipefail).
    ! docker logs --since "$started" "$container" 2>&1 | grep -F -- "$DEPLOY_FAILED" >/dev/null
}
