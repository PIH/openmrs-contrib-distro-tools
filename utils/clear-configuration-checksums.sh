#!/bin/bash
# General-purpose: removes openmrs-module-initializer's cached configuration_checksums from an
# openmrs-data volume, so the next start reprocesses all configuration from scratch rather than
# trusting checksums that may no longer reflect reality (e.g. after loading a different database
# while keeping an existing openmrs-data). Usage:
#   utils/clear-configuration-checksums.sh --volume=<openmrs-data volume name>
set -euo pipefail

VOLUME=
for arg in "$@"; do
    case "$arg" in
        --volume=*) VOLUME="${arg#*=}" ;;
        *) echo "unknown argument: $arg" >&2; exit 1 ;;
    esac
done
[ -z "$VOLUME" ] && { echo "usage: $0 --volume=<openmrs-data volume name>" >&2; exit 1; }
docker volume inspect "$VOLUME" >/dev/null 2>&1 || { echo "error: no such volume: $VOLUME" >&2; exit 1; }

RUNNING=$(docker ps --filter "volume=$VOLUME" -q)
[ -n "$RUNNING" ] && { echo "error: $VOLUME is in use by a running container -- stop it first." >&2; exit 1; }

echo "Clearing configuration_checksums from $VOLUME..." >&2
docker run --rm -v "$VOLUME:/data" alpine:3.21 rm -rf /data/configuration_checksums
echo "Cleared configuration_checksums from $VOLUME. The next start will reprocess all configuration." >&2
