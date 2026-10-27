#!/usr/bin/env bats
# backup-pgdump, and `openmrs-docker <name> backup` on a DHIS2 instance, round-tripped through
# initialize. The dhis2 service runs the stub image (build_stub_dhis2_image) with a dummy WAR.

load ../helpers

setup_file() { build_stub_dhis2_image; }

setup() {
    cd "$BATS_TEST_TMPDIR"
    A="$(instance a)"
    B="$(instance b)"
}
teardown() {
    destroy_instance "$A"
    destroy_instance "$B"
    common_teardown
}

create_dhis2() { # <name> [VAR=value...]
    local name=$1; shift
    env "$@" SERVICES=dhis2-db,dhis2 DHIS2_IMAGE_NAME="$STUB_DHIS2_IMAGE" DHIS2_IMAGE_TAG=latest \
        DHIS2_VERSION=2.41.8.1 "$BIN/openmrs-docker" create "$name" >/dev/null
    mkdir -p "$OPENMRS_DOCKER_HOME/$name/wars" && echo war > "$OPENMRS_DOCKER_HOME/$name/wars/dhis2-2.41.8.1.war"
}
start_db() { # <name>
    "$BIN/openmrs-docker" "$1" start >/dev/null 2>&1
    "$UTILS/wait-for-healthy.sh" --container="$1-dhis2-db" --timeout=120 >/dev/null 2>&1
}
psql_in() { # <name> <sql>
    docker exec "$1-dhis2-db" psql -U dhis -d dhis -tAc "$2"
}

@test "pg_dump password is not in docker argv" {
    local secret='s3cret-$HOME"pw'
    create_dhis2 "$A" DHIS2_DB_PASSWORD="$secret"
    start_db "$A"
    record_docker_argv
    run "$UTILS/backup-pgdump.sh" --container="$A-dhis2-db" --output=dump.sql
    assert_success
    assert_not_in_docker_argv "$secret"
}

@test "excludes only analytics tables by default" {
    create_dhis2 "$A"
    start_db "$A"
    # aggregatedataexchange is a real table from 2.39; DHIS2 won't start without it.
    psql_in "$A" 'CREATE TABLE marker (v text); CREATE TABLE analytics_2024 (v text); CREATE TABLE aggregatedataexchange (v text); CREATE TABLE completenesstarget (v text);' >/dev/null
    run "$UTILS/backup-pgdump.sh" --container="$A-dhis2-db" --output=dump.sql
    assert_success
    run grep -c -E 'CREATE TABLE public\.(marker|aggregatedataexchange|completenesstarget) ' dump.sql
    assert_output 3
    run grep analytics_2024 dump.sql
    assert_failure
    run grep -E 'OWNER TO|GRANT ' dump.sql
    assert_failure
}

@test "backup then initialize round-trips the database and the DHIS2 home" {
    create_dhis2 "$A"
    start_db "$A"
    psql_in "$A" "CREATE TABLE marker (v text); INSERT INTO marker VALUES ('round-trip');" >/dev/null
    docker run --rm -v "${A}_dhis2-data:/h" "$ALPINE_IMAGE" sh -c 'mkdir -p /h/files && echo x > /h/files/x'
    ARCHIVE_PASSWORD=pw run "$BIN/openmrs-docker" "$A" backup --output-dir="$BATS_TEST_TMPDIR/out"
    assert_success
    local db data
    db=$(ls out/"$A"_*.sql.7z)
    data=$(ls out/"$A"_data_*.7z)
    create_dhis2 "$B"
    ARCHIVE_PASSWORD=pw run_initialize "$B" RESTORE_PGDUMP_PATH="$db" RESTORE_DHIS2_DATA_PATH="$data"
    assert_success
    start_db "$B"
    run psql_in "$B" 'SELECT v FROM marker'
    assert_output round-trip
    run docker run --rm -v "${B}_dhis2-data:/h" "$ALPINE_IMAGE" cat /h/files/x
    assert_output x
}

@test "backup refuses on an OpenMRS instance" {
    SERVICES=openmrs-db create_instance "$A"
    ARCHIVE_PASSWORD=pw run "$BIN/openmrs-docker" "$A" backup --output-dir="$BATS_TEST_TMPDIR/out"
    assert_failure
    assert_output --partial "isn't implemented for OpenMRS instances yet"
}
