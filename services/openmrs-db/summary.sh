#!/bin/bash
# `pihx <instance> summary`: the database's [server], [databases], [rows], [objects], [recent] and
# [accounts] sections (utils/fingerprint.sh). From the running container if there is one; otherwise
# from the stopped instance's db-data volume, started read-only with the instance's own image and
# server options (OPENMRS_DB_OPT_*, as compose.yaml turns them into flags), so it reads as the
# running one does -- e.g. right after `initialize`. Run through pihx, which sets the environment
# (pihx/script.py).
set -euo pipefail
container="$SERVICE_NAME-openmrs-db"
if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" = true ]; then
    MYSQL_PASSWORD="$OPENMRS_DB_ROOT_PASSWORD" exec "$PIHX_TOOLS/utils/fingerprint.sh" \
        --container="$container" --user=root --database=openmrs
fi
volume="${SERVICE_NAME}_db-data"
docker volume inspect "$volume" >/dev/null 2>&1 || {
    echo "error: $volume doesn't exist -- nothing to summarize" >&2
    exit 1
}
args=(--db-volume="$volume" --image="$OPENMRS_DB_IMAGE_NAME:$OPENMRS_DB_IMAGE_TAG" --database=openmrs)
for var in "${!OPENMRS_DB_OPT_@}"; do
    opt="${var#OPENMRS_DB_OPT_}"
    opt="${opt//_/-}"
    if [ -n "${!var}" ]; then args+=(--server-opt="--$opt=${!var}"); else args+=(--server-opt="--$opt"); fi
done
exec "$PIHX_TOOLS/utils/fingerprint.sh" "${args[@]}"
