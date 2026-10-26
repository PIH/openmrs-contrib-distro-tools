#!/bin/bash
# Mounted into dhis2-db's /docker-entrypoint-initdb.d by initialize's restore overlays, so the
# Postgres image's entrypoint runs it on first start, after its own PostGIS setup (10_postgis.sh,
# which a directory mounted there would hide). Imports /restore/dump.sql or /restore/dump.sql.gz,
# stopping at the first error.
set -euo pipefail
psql=(psql -v ON_ERROR_STOP=1 --no-password --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --quiet)
if [ -f /restore/dump.sql.gz ]; then
    echo "Importing /restore/dump.sql.gz into $POSTGRES_DB..."
    gunzip -c /restore/dump.sql.gz | "${psql[@]}"
elif [ -f /restore/dump.sql ]; then
    echo "Importing /restore/dump.sql into $POSTGRES_DB..."
    "${psql[@]}" -f /restore/dump.sql
else
    echo "error: no dump at /restore/dump.sql or /restore/dump.sql.gz" >&2
    exit 1
fi
echo "Imported the dump into $POSTGRES_DB."
