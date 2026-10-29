#!/bin/bash
# `pihx <instance> summary`: the database's [server], [databases], [rows], [objects], [recent] and
# [accounts] sections, read from the running container (utils/fingerprint.sh). Run through
# pihx, which sets the environment (pihx/script.py).
set -euo pipefail
docker inspect -f '{{.State.Running}}' "$SERVICE_NAME-openmrs-db" 2>/dev/null | grep -qx true || {
    echo "error: $SERVICE_NAME-openmrs-db isn't running -- start it ('pihx $PIHX_INSTANCE start') to summarize it" >&2
    exit 1
}
MYSQL_PASSWORD="$OPENMRS_DB_ROOT_PASSWORD" exec "$PIHX_TOOLS/utils/fingerprint.sh" \
    --container="$SERVICE_NAME-openmrs-db" --user=root --database=openmrs
