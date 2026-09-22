#!/bin/bash
# General-purpose: polls any container until it reports healthy. Usage:
#   utils/wait-for-healthy.sh --container=<name> [--timeout=<seconds>] [--fail-on-unhealthy=true|false]
#
# Fails fast if the container is exited, dead, or restarting (a container declared
# `restart: unless-stopped` crash-loops rather than settling on exited/dead, so `restarting` has
# to be checked too, or this would poll the full timeout against a container that's never coming
# back), or times out after --timeout (default 600s). If --fail-on-unhealthy is true (default
# false), a Health.Status of "unhealthy" is also treated as an immediate failure rather than
# kept polling through -- useful for a container whose healthcheck can legitimately report
# unhealthy while a long-running first-boot operation is still in progress.
set -euo pipefail

CONTAINER=
TIMEOUT=600
FAIL_ON_UNHEALTHY=false
for arg in "$@"; do
    case "$arg" in
        --container=*) CONTAINER="${arg#*=}" ;;
        --timeout=*) TIMEOUT="${arg#*=}" ;;
        --fail-on-unhealthy=*) FAIL_ON_UNHEALTHY="${arg#*=}" ;;
        *) echo "unknown argument: $arg" >&2; exit 1 ;;
    esac
done
[ -z "$CONTAINER" ] && { echo "usage: $0 --container=<name> [--timeout=<seconds>] [--fail-on-unhealthy=true|false]" >&2; exit 1; }
case "$TIMEOUT" in
    ''|*[!0-9]*|0) echo "error: --timeout must be a positive integer, got '$TIMEOUT'" >&2; exit 1 ;;
esac
docker inspect "$CONTAINER" >/dev/null 2>&1 || { echo "error: no such container: $CONTAINER" >&2; exit 1; }

INTERVAL=5
ATTEMPTS=$(( (TIMEOUT + INTERVAL - 1) / INTERVAL ))
echo "Waiting for $CONTAINER to become healthy (timeout: ${TIMEOUT}s)..." >&2
for i in $(seq 1 "$ATTEMPTS"); do
    case "$(docker inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null || true)" in
        exited|dead|restarting)
            echo "error: $CONTAINER exited unexpectedly -- check 'docker logs $CONTAINER'." >&2
            exit 1
            ;;
    esac
    STATUS=$(docker inspect --format '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || true)
    if [ "$STATUS" = "healthy" ]; then
        echo "$CONTAINER is healthy." >&2
        exit 0
    fi
    if [ "$FAIL_ON_UNHEALTHY" = "true" ] && [ "$STATUS" = "unhealthy" ]; then
        echo "error: $CONTAINER reported unhealthy -- check 'docker logs $CONTAINER'." >&2
        exit 1
    fi
    if [ "$i" -eq "$ATTEMPTS" ]; then
        echo "error: timed out after ${TIMEOUT}s waiting for $CONTAINER to become healthy" >&2
        exit 1
    fi
    sleep "$INTERVAL"
done
