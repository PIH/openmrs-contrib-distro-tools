#!/bin/bash
# Waits until a container's healthcheck reports healthy. Fails at once if the container stops or
# restarts (a crash-looping `restart: unless-stopped` container never settles on "exited").
#
# Usage: openmrs-utils wait-for-healthy --container=<name> [--timeout=600]
#            [--fail-on-unhealthy=false]
#   --timeout                 seconds to wait
#   --fail-on-unhealthy=true  fails at the first "unhealthy" instead of waiting on (leave it off
#                             for a container that can report unhealthy during a long first start)
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

CONTAINER=
TIMEOUT=600
FAIL_ON_UNHEALTHY=false
for arg in "$@"; do
    case "$arg" in
        --container=*) CONTAINER="${arg#*=}" ;;
        --timeout=*) TIMEOUT="${arg#*=}" ;;
        --fail-on-unhealthy=*) FAIL_ON_UNHEALTHY="${arg#*=}" ;;
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
    [ "$(date +%s)" -lt "$DEADLINE" ] || die "timed out after ${TIMEOUT}s waiting for $CONTAINER to become healthy"
    sleep 1
done
