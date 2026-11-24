#!/bin/bash
# `pihx <instance> summary`: the [dhis2-db] section: row counts of DHIS2's main tables (only those
# that exist) and the latest successful Flyway migration, so a restore can be compared with its
# source. Counts only, no row contents. From the running container if there is one; otherwise from
# the stopped instance's dhis2-db-data volume, with a throwaway server started on it from the
# instance's own image (no network), as the running one would answer -- e.g. right after
# `initialize`. Run through pihx, which sets the environment (pihx/script.py).
set -euo pipefail
container="$SERVICE_NAME-dhis2-db"

# Runs inside the database container, with PGUSER and PGDATABASE set; psql reaches the server over
# its socket, which the image trusts.
queries='
q() { psql -X -tA -v ON_ERROR_STOP=1 -c "$1"; }
exists() { [ "$(q "SELECT to_regclass('"'"'public.$1'"'"') IS NOT NULL")" = t ]; }
# "rows <name> <count>", <name> the same on every DHIS2 version: the rows of the first of <tables> that
# exists, each a +-joined list of tables whose rows are added up (all must exist).
count_as() { # <name> <tables>...
    local name=$1 group table sum; shift
    for group in "$@"; do
        sum=0
        for table in ${group//+/ }; do
            exists "$table" || continue 2
            sum=$((sum + $(q "SELECT count(*) FROM public.$table")))
        done
        echo "rows $name $sum"
        return
    done
}
count_as datavalue datavalue
# trackedentityinstance first: up to 2.40 a trackedentity table can be the pre-2.29 types table.
count_as trackedentity trackedentityinstance trackedentity
# programstageinstance up to 2.40, event in 2.41 and 2.42, split in two from 2.43.
count_as event programstageinstance event trackerevent+singleevent
count_as userinfo userinfo
count_as organisationunit organisationunit
if exists flyway_schema_history; then
    version=$(q "SELECT version FROM flyway_schema_history WHERE success AND version IS NOT NULL ORDER BY installed_rank DESC LIMIT 1")
    [ -z "$version" ] || echo "flyway $version"
fi
'

echo "[dhis2-db]"
if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" = true ]; then
    docker exec -e PGUSER="$DHIS2_DB_USER" -e PGDATABASE="$DHIS2_DB_NAME" "$container" \
        bash -c "$queries" | LC_ALL=C sort
    exit 0
fi
volume="${SERVICE_NAME}_dhis2-db-data"
docker volume inspect "$volume" >/dev/null 2>&1 || {
    echo "error: $volume doesn't exist -- nothing to summarize" >&2
    exit 1
}
# Starts the server on the volume as the postgres user, as the image's entrypoint does, asks, and
# stops it cleanly.
# shellcheck disable=SC2016 # runs in the container
docker run --rm --network none -e PGUSER="$DHIS2_DB_USER" -e PGDATABASE="$DHIS2_DB_NAME" \
    -e QUERIES="$queries" --mount "type=volume,source=$volume,target=/var/lib/postgresql/data" \
    --entrypoint bash "$DHIS2_DB_IMAGE_NAME:$DHIS2_DB_IMAGE_TAG" -c '
        if [ ! -f /var/lib/postgresql/data/PG_VERSION ]; then echo "no database" >&2; exit 1; fi
        gosu postgres pg_ctl -D /var/lib/postgresql/data -o "-c listen_addresses=" -w -s -l /tmp/pg.log start >/dev/null \
            || { cat /tmp/pg.log >&2; exit 1; }
        status=0
        gosu postgres bash -c "$QUERIES" || status=$?
        gosu postgres pg_ctl -D /var/lib/postgresql/data -m fast -w -s stop >/dev/null
        exit $status
    ' | LC_ALL=C sort
