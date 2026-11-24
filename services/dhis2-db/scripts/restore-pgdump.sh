#!/bin/bash
# Mounted into dhis2-db's /docker-entrypoint-initdb.d by initialize's restore overlays, so the
# Postgres image's entrypoint runs it on first start, after its own PostGIS setup (10_postgis.sh,
# which a directory mounted there would hide). Imports the one dump in /restore (*.sql or *.sql.gz)
# into the then empty database, stopping at the first error.
set -euo pipefail
psql=(psql -v ON_ERROR_STOP=1 --no-password --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --quiet)
# The image's PostGIS setup also adds topology and the TIGER geocoder, with their own schemas. Without
# them the database is empty, and the dump recreates exactly the extensions its source had (pg_dump
# writes CREATE EXTENSION IF NOT EXISTS, but CREATE SCHEMA plainly).
"${psql[@]}" -c 'DROP EXTENSION IF EXISTS postgis_tiger_geocoder, postgis_topology, fuzzystrmatch, postgis CASCADE' \
    -c 'DROP SCHEMA IF EXISTS tiger, tiger_data, topology CASCADE'
dump=""
for candidate in /restore/*.sql.gz /restore/*.sql; do
    if [ -f "$candidate" ]; then dump=$candidate; break; fi
done
if [ -z "$dump" ]; then
    echo "error: no dump (*.sql or *.sql.gz) in /restore" >&2
    exit 1
fi
# The mounted file keeps its host owner and mode, and this runs as the image's postgres user.
if [ ! -r "$dump" ]; then
    echo "error: can't read $(basename "$dump"): dhis2-db imports it as its own user (uid $(id -u)), not as the file's owner. Make it readable by others (chmod o+r) and try again." >&2
    exit 1
fi
echo "Importing $dump into $POSTGRES_DB..."
case "$dump" in
    *.gz) gunzip -c "$dump" | "${psql[@]}" ;;
    *)    "${psql[@]}" -f "$dump" ;;
esac
echo "Imported the dump into $POSTGRES_DB."
