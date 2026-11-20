#!/bin/bash
# `pihx <instance> summary`: the [openhim] section, each collection's document count in OpenHIM's
# openhim database and the newest transaction's time. From the running mongo-db if there is one;
# otherwise from the stopped instance's mongo-data volume, with a throwaway mongod of the instance's
# own image (no network), e.g. right after `initialize`. Run through pihx, which sets the
# environment (pihx/script.py).
set -euo pipefail
QUERY='
db.getCollectionNames().forEach(c => print("documents " + c + " " + db.getCollection(c).countDocuments({})));
const t = db.transactions.find({}, {"request.timestamp": 1}).sort({"request.timestamp": -1}).limit(1).toArray();
if (t.length && t[0].request && t[0].request.timestamp) print("newest transaction " + t[0].request.timestamp.toISOString());
'
summarize() { # <container>
    echo "[openhim]"
    docker exec "$1" mongosh --quiet openhim --eval "$QUERY" | LC_ALL=C sort
}

container="$SERVICE_NAME-mongo-db"
if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" = true ]; then
    summarize "$container"
    exit 0
fi
volume="${SERVICE_NAME}_mongo-data"
docker volume inspect "$volume" >/dev/null 2>&1 || {
    echo "error: $volume doesn't exist -- nothing to summarize" >&2
    exit 1
}
temp="$SERVICE_NAME-summary-mongo-db"
docker rm -f "$temp" >/dev/null 2>&1 || true
trap 'docker rm -f "$temp" >/dev/null 2>&1 || true' EXIT
docker run -d --name "$temp" --network none --mount "type=volume,source=$volume,target=/data/db" \
    "$OPENHIM_MONGO_IMAGE_NAME:$OPENHIM_MONGO_IMAGE_TAG" \
    --bind_ip 127.0.0.1 --wiredTigerCacheSizeGB "${OPENHIM_MONGO_CACHE_SIZE_GB:-0.25}" >/dev/null
for _ in $(seq 120); do
    if docker exec "$temp" mongosh --quiet --eval 'quit(db.adminCommand("ping").ok ? 0 : 1)' >/dev/null 2>&1; then
        summarize "$temp"
        exit 0
    fi
    sleep 1
done
echo "error: MongoDB didn't start on $volume within 2 minutes" >&2
exit 1
