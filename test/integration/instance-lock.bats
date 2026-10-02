#!/usr/bin/env bats
# A real initialize holds the instance lock for its whole run, so puppet's `start` can't interleave.

load ../helpers

setup() { cd "$BATS_TEST_TMPDIR"; }
teardown() {
    [ -n "${NAME:-}" ] && destroy_instance "$NAME"
    common_teardown
}

@test "start refuses while initialize runs, and works once it's done" {
    NAME="$(instance)"
    SERVICES=openmrs-db create_instance "$NAME"
    write_tiny_dump dump.sql
    RESTORE_MYSQL_DUMP_PATH=dump.sql timeout 300 "$BIN/openmrs-docker" "$NAME" initialize > init.log 2>&1 3>&- &
    local init=$!
    until grep -q 'Waiting for' init.log; do
        kill -0 "$init" 2>/dev/null || { cat init.log; fail "initialize ended early"; }
        sleep 0.2
    done
    run "$BIN/openmrs-docker" "$NAME" start
    assert_failure
    assert_output --partial "$NAME is busy: initialize (pid"
    wait "$init"
    run "$BIN/openmrs-docker" "$NAME" start
    assert_success
}

@test "run-service holds the lock for a service that declares it (petl), so a deploy waits for it" {
    NAME="$(instance)"
    PETL_IMAGE_NAME=alpine PETL_IMAGE_TAG=3.21 PETL_MYSQL_PASSWORD=Pw-1 PETL_SQLSERVER_PASSWORD=Pw-1 \
        SERVICES=openmrs-db,petl create_instance "$NAME"
    "$BIN/openmrs-docker" "$NAME" start >/dev/null 2>&1   # a PETL run is against the running instance
    "$BIN/openmrs-docker" "$NAME" run-service petl sleep 8 > petl.log 2>&1 3>&- &
    local petl=$!
    until grep -q 'run-service' "$OPENMRS_DOCKER_HOME/$NAME/.lock" 2>/dev/null && docker ps --format '{{.Names}}' | grep -q "^$NAME-petl"; do
        kill -0 "$petl" 2>/dev/null || { cat petl.log; fail "run-service ended early"; }
        sleep 0.2
    done
    run "$BIN/openmrs-docker" "$NAME" start
    assert_failure
    assert_output --partial "$NAME is busy: run-service"
    run env OPENMRS_DOCKER_LOCK_WAIT=60 "$BIN/openmrs-docker" "$NAME" start
    assert_success
    wait "$petl"
}
