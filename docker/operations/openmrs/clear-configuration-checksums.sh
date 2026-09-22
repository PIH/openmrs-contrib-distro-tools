#!/bin/bash
# Usage: openmrs-docker <name> openmrs clear-configuration-checksums
#
# Removes openmrs-module-initializer's cached configuration_checksums from the openmrs-data
# volume, so the next start reprocesses all configuration from scratch rather than trusting
# checksums that may no longer reflect reality -- e.g. after loading a different database into
# openmrs-db while keeping this instance's existing openmrs-data (this only matters for an
# instance where that combination is actually possible; the current restore-dump/restore-percona
# operations always refuse to run against an instance that already has data, so it doesn't yet
# arise from them). Sourced into bin/openmrs-docker, not run standalone: relies on
# COMPOSE_FILES, NAME, and SERVICE_NAME already being in scope.
set -euo pipefail

if ! docker volume inspect "${SERVICE_NAME}_openmrs-data" >/dev/null 2>&1; then
    echo "error: ${SERVICE_NAME}_openmrs-data does not exist yet -- nothing to clear." >&2
    exit 1
fi

RUNNING_CONTAINER=$(docker compose "${COMPOSE_FILES[@]}" ps -q openmrs)
if [ -n "$RUNNING_CONTAINER" ]; then
    echo "error: openmrs is currently running -- stop it first ('$0 $NAME stop') so the volume isn't modified while in use." >&2
    exit 1
fi

echo "Clearing configuration_checksums from ${SERVICE_NAME}_openmrs-data..."
docker run --rm -v "${SERVICE_NAME}_openmrs-data:/data" alpine rm -rf /data/configuration_checksums
echo "Cleared configuration_checksums for $NAME. The next start will reprocess all configuration."
