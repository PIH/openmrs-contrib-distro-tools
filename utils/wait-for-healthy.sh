#!/bin/bash
# Waits until a container's healthcheck reports healthy. Fails at once if the container stops or
# restarts (a crash-looping `restart: unless-stopped` container never settles on "exited").
#
# Usage: openmrs-utils wait-for-healthy --container=<name> [--timeout=600]
#            [--fail-on-unhealthy=false] [--fail-on-log=<pattern>]
#   --timeout                 seconds to wait
#   --fail-on-unhealthy=true  fails at the first "unhealthy" instead of waiting on (leave it off
#                             for a container that can report unhealthy during a long first start)
#   --fail-on-log             fails, showing the line, as soon as the container logs one matching
#                             <pattern> (grep -E) since its current start: for a failure that leaves it
#                             running but never healthy, such as a web app Tomcat failed to deploy
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

CONTAINER=
TIMEOUT=600
FAIL_ON_UNHEALTHY=false
FAIL_ON_LOG=
for arg in "$@"; do
    case "$arg" in
        --container=*) CONTAINER="${arg#*=}" ;;
        --timeout=*) TIMEOUT="${arg#*=}" ;;
        --fail-on-unhealthy=*) FAIL_ON_UNHEALTHY="${arg#*=}" ;;
        --fail-on-log=*) FAIL_ON_LOG="${arg#*=}" ;;
        *) die "unknown argument: $arg" ;;
    esac
done
[ -n "$CONTAINER" ] || usage
case "$TIMEOUT" in
    ''|*[!0-9]*|0) die "--timeout must be a positive integer, got '$TIMEOUT'" ;;
esac
docker inspect "$CONTAINER" >/dev/null 2>&1 || die "no such container: $CONTAINER"
# Test is ["NONE"] when the image's healthcheck was turned off.
case "$(docker inspect --format '{{with .Config.Healthcheck}}{{index .Test 0}}{{end}}' "$CONTAINER")" in
    ''|NONE) die "$CONTAINER has no healthcheck to wait for" ;;
esac

# Against a deadline, so the time `docker inspect` takes doesn't stretch the timeout.
DEADLINE=$(( $(date +%s) + TIMEOUT ))
# Each look at the log reads only what's new since the last, overlapping by a second.
LOG_SINCE=$(docker inspect --format '{{.State.StartedAt}}' "$CONTAINER")
note "Waiting for $CONTAINER to become healthy (timeout: ${TIMEOUT}s)..."
while true; do
    case "$(docker inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null || true)" in
        exited|dead|restarting) die "$CONTAINER exited unexpectedly -- check 'docker logs $CONTAINER'." ;;
    esac
    STATUS=$(docker inspect --format '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || true)
    [ "$STATUS" != healthy ] || { note "$CONTAINER is healthy."; exit 0; }
    if [ "$FAIL_ON_UNHEALTHY" = true ] && [ "$STATUS" = unhealthy ]; then
        die "$CONTAINER reported unhealthy -- check 'docker logs $CONTAINER'."
    fi
    if [ -n "$FAIL_ON_LOG" ]; then
        now=$(( $(date +%s) - 1 ))
        line=$(docker logs --since "$LOG_SINCE" "$CONTAINER" 2>&1 | grep -E -m1 -- "$FAIL_ON_LOG" || true)
        [ -z "$line" ] || die "$CONTAINER logged: $line -- check 'docker logs $CONTAINER'."
        LOG_SINCE=$now
    fi
    [ "$(date +%s)" -lt "$DEADLINE" ] || die "timed out after ${TIMEOUT}s waiting for $CONTAINER to become healthy"
    sleep 1
done
