#!/usr/bin/env bats
# initialize on a DHIS2 instance: dhis2-db-data from a pg_dump (.sql, .sql.gz, or a .7z/.zip of
# one), dhis2-data from a directory or archive of a DHIS2 home. Hand-written SQL fixtures stand in for
# dumps; backup-pgdump's own output is round-tripped in dhis2-backup.bats.

load ../helpers

setup() {
    cd "$BATS_TEST_TMPDIR"
    NAME="$(instance)"
    SERVICES=dhis2-db,dhis2 DHIS2_VERSION=2.41.8.1 DHIS2_IMAGE_TAG=9-jdk17 create_instance "$NAME"
}
teardown() {
    destroy_instance "$NAME"
    common_teardown
}

write_dump() { # <path> [extra SQL...]
    {
        echo "CREATE EXTENSION IF NOT EXISTS postgis;"
        echo "CREATE TABLE marker (v text);"
        echo "INSERT INTO marker VALUES ('restored');"
        local line; for line in "${@:2}"; do echo "$line"; done
    } > "$1"
}
# The marker row, read through the instance's own dhis2-db.
marker() {
    "$BIN/openmrs-docker" "$NAME" start >/dev/null 2>&1 || true
    "$UTILS/wait-for-healthy.sh" --container="$NAME-dhis2-db" --timeout=120 >/dev/null 2>&1
    docker exec "$NAME-dhis2-db" psql -U dhis -d dhis -tAc 'SELECT v FROM marker'
}
volumes() { docker volume ls -q --filter "name=^${NAME}_"; }

@test "restores a .sql.gz dump into dhis2-db-data" {
    write_dump dump.sql && gzip dump.sql
    run_initialize "$NAME" RESTORE_PGDUMP_PATH=dump.sql.gz
    assert_success
    run volumes
    refute_output --partial db-init
    # Only the database is started to check it; the dhis2 service would need a WAR.
    run docker run --rm -v "${NAME}_dhis2-db-data:/d" "$ALPINE_IMAGE" test -s /d/PG_VERSION
    assert_success
    "$BIN/openmrs-docker" "$NAME" remove-service dhis2 >/dev/null
    run marker
    assert_output restored
}

@test "restores a dump from an encrypted .7z" {
    write_dump dump.sql
    docker run --rm -v "$BATS_TEST_TMPDIR:/w" -w /w "$P7ZIP_IMAGE" 7z a -ppw /w/dump.7z dump.sql >/dev/null
    ARCHIVE_PASSWORD=pw run_initialize "$NAME" RESTORE_PGDUMP_PATH=dump.7z
    assert_success
    "$BIN/openmrs-docker" "$NAME" remove-service dhis2 >/dev/null
    run marker
    assert_output restored
}

@test "restores a dump that has owner and grant statements" {
    write_dump dump.sql 'ALTER TABLE public.marker OWNER TO dhis;' 'GRANT ALL ON TABLE public.marker TO dhis;'
    run_initialize "$NAME" RESTORE_PGDUMP_PATH=dump.sql
    assert_success
    "$BIN/openmrs-docker" "$NAME" remove-service dhis2 >/dev/null
    run marker
    assert_output restored
}

@test "a failing dump fails initialize and leaves no volumes" {
    { echo 'DROP TABLE marker;'; cat <(write_dump /dev/stdout); } > dump.sql
    run_initialize "$NAME" RESTORE_PGDUMP_PATH=dump.sql
    assert_failure
    assert_output --partial 'table "marker" does not exist'
    assert_output --partial 'backup-pgdump'
    run volumes
    assert_output ''
}

@test "restores dhis2-data from an archive" {
    write_dump dump.sql
    mkdir -p home/files && echo x > home/files/x
    tar czf home.tar.gz home
    run_initialize "$NAME" RESTORE_PGDUMP_PATH=dump.sql RESTORE_DHIS2_DATA_PATH=home.tar.gz
    assert_success
    run docker run --rm -v "${NAME}_dhis2-data:/d" "$ALPINE_IMAGE" cat /d/files/x
    assert_output x
}

@test "refuses without RESTORE_PGDUMP_PATH" {
    run_initialize "$NAME"
    assert_failure
    assert_output --partial RESTORE_PGDUMP_PATH
    run volumes
    assert_output ''
}

@test "refuses when a data volume already exists" {
    docker volume create "${NAME}_dhis2-db-data" >/dev/null
    write_dump dump.sql
    run_initialize "$NAME" RESTORE_PGDUMP_PATH=dump.sql
    assert_failure
    assert_output --partial 'already exists'
}
