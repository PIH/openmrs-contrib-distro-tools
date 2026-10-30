#!/usr/bin/env bats
# start, wait, status, restart, stop, pull and update, through openmrs-docker, against a stub
# OpenMRS image (see build_stub_openmrs_image).

load ../helpers

setup_file() { build_stub_openmrs_image; }

setup() {
    cd "$BATS_TEST_TMPDIR"
    NAME="$(instance)"
    DIR="$PIHX_HOME/$NAME"
}
teardown() {
    remove_test_instance "$NAME"
    common_teardown
}

create_with_stub() { OPENMRS_IMAGE_NAME="$STUB_OPENMRS_IMAGE" OPENMRS_IMAGE_TAG=latest create_instance "$NAME"; }
running() { docker ps --format '{{.Names}}' --filter "label=com.docker.compose.project=$NAME" | sort; }

@test "start brings the stack up, wait sees OpenMRS ready, and stop removes the containers but keeps the volumes" {
    create_with_stub
    run "$BIN/openmrs-docker" "$NAME" start
    assert_success
    run "$BIN/openmrs-docker" "$NAME" wait
    assert_success
    assert_output --partial "$NAME is ready."
    assert_equal "$(running)" "$(printf '%s\n' "$NAME-openmrs" "$NAME-openmrs-db")"
    run "$BIN/openmrs-docker" "$NAME" status
    assert_success
    assert_output --partial "$NAME-openmrs-db"
    run "$BIN/openmrs-docker" "$NAME" restart
    assert_success
    run "$BIN/openmrs-docker" "$NAME" stop
    assert_success
    assert_equal "$(running)" ""
    run docker volume inspect "${NAME}_db-data" "${NAME}_openmrs-data"
    assert_success
}

create_tables() { # what the running openmrs container got
    docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$NAME-openmrs" | sed -n 's/^OMRS_CONFIG_CREATE_TABLES=//p'
}

container_id() { docker inspect -f '{{.Id}}' "$NAME-openmrs"; }

@test "a new instance's first start has OpenMRS create the tables; once it has been healthy, the next start decides from the database" {
    local id
    create_with_stub
    run "$BIN/openmrs-docker" "$NAME" start
    assert_success
    assert_output --partial 'openmrs: the database has no tables: OpenMRS will create them'
    run "$BIN/openmrs-docker" "$NAME" wait
    assert_success
    run create_tables
    assert_output true
    id=$(container_id)
    # What OpenMRS's install did.
    mysql_exec "$NAME-openmrs-db" openmrs 'CREATE TABLE openmrs.installed (id INT)'
    # It has been healthy, so the install may have finished: the database decides, and the
    # container is recreated with false.
    run "$BIN/openmrs-docker" "$NAME" start
    assert_success
    assert_output --partial "openmrs: the openmrs container can't keep its create_tables; checking the database"
    assert_output --partial "openmrs: the database has tables: OpenMRS won't create them"
    [ "$(container_id)" != "$id" ] || fail "the openmrs container wasn't recreated"
    run create_tables
    assert_output false
}

@test "a start during OpenMRS's first install keeps the container and its true; once it has restarted, the database decides" {
    local id
    OMRS_EXTRA_stub_installing=1 create_with_stub
    run "$BIN/openmrs-docker" "$NAME" start
    assert_success
    assert_output --partial 'openmrs: the database has no tables: OpenMRS will create them'
    id=$(container_id)
    # Part way through the install.
    mysql_exec "$NAME-openmrs-db" openmrs 'CREATE TABLE openmrs.installing (id INT)'
    run "$BIN/openmrs-docker" "$NAME" start
    assert_success
    assert_output --partial 'openmrs: the openmrs container is still on its first start: keeping its create_tables (true)'
    assert_equal "$(container_id)" "$id"
    run create_tables
    assert_output true
    # Once it has stopped (here a restart), its install can't be told from a finished one.
    docker restart -t 0 "$NAME-openmrs" >/dev/null
    run "$BIN/openmrs-docker" "$NAME" start
    assert_success
    assert_output --partial "openmrs: the database has tables: OpenMRS won't create them"
    [ "$(container_id)" != "$id" ] || fail "the openmrs container wasn't recreated"
    run create_tables
    assert_output false
}

@test "a restored instance starts without OpenMRS creating tables" {
    create_with_stub
    write_tiny_dump dump.sql
    run_initialize "$NAME" --from "$(from_folder openmrs-db.sql dump.sql)"
    assert_success
    run "$BIN/openmrs-docker" "$NAME" start
    assert_success
    assert_output --partial "openmrs: the database has tables: OpenMRS won't create them"
    run "$BIN/openmrs-docker" "$NAME" wait
    assert_success
    run create_tables
    assert_output false
}

@test "wait fails as soon as OpenMRS exits, rather than waiting out its timeout" {
    OMRS_EXTRA_stub_exit=1 create_with_stub
    "$BIN/openmrs-docker" "$NAME" start >/dev/null 2>&1
    run timeout 120 "$BIN/openmrs-docker" "$NAME" wait
    assert_failure
    # Docker restarts it (restart: unless-stopped), so wait may see it exited or its healthcheck failed
    assert_output --regexp 'exited unexpectedly|reported unhealthy'
    assert_output --partial "$NAME-openmrs did not become ready"
}

@test "update starts an instance" {
    create_instance "$NAME" --services=openmrs-db
    run "$BIN/openmrs-docker" "$NAME" update
    assert_success
    docker wait "$NAME-openmrs-db-accounts" >/dev/null   # the one-shot account setup, done once it exits
    assert_equal "$(running)" "$NAME-openmrs-db"
}

@test "pull fetches the instance's images without starting anything" {
    create_instance "$NAME" --services=openmrs-db
    run "$BIN/openmrs-docker" "$NAME" pull
    assert_success
    assert_equal "$(running)" ""
}

@test "wait shows only what OpenMRS logs from when it starts waiting, not the container's whole history" {
    create_with_stub
    "$BIN/openmrs-docker" "$NAME" start >/dev/null 2>&1
    docker exec "$NAME-openmrs" sh -c 'echo OLD-LOG-LINE > /proc/1/fd/1'
    sleep 1
    run "$BIN/openmrs-docker" "$NAME" wait
    assert_success
    assert_output --partial "$NAME is ready."
    refute_output --partial 'OLD-LOG-LINE'
}

@test "run-service petl doesn't need OpenMRS: it runs, and leaves OpenMRS stopped, on an instance that has it" {
    PETL_IMAGE_NAME=alpine PETL_IMAGE_TAG=3.21 PETL_MYSQL_PASSWORD=Pw-1 PETL_SQLSERVER_PASSWORD=Pw-1 \
        OPENMRS_IMAGE_NAME="$STUB_OPENMRS_IMAGE" OPENMRS_IMAGE_TAG=latest create_instance "$NAME" --services=openmrs-db,openmrs,petl
    # The database running, OpenMRS stopped (e.g. PETL against a restored database).
    "$BIN/openmrs-docker" "$NAME" start >/dev/null 2>&1
    docker stop "$NAME-openmrs" >/dev/null
    run "$BIN/openmrs-docker" "$NAME" run-service petl echo PETL-RAN
    assert_success
    assert_output --partial 'PETL-RAN'
    refute_output --partial 'OpenMRS'
    run docker ps -q --filter "name=^$NAME-openmrs$"
    assert_output ''
}
