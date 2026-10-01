#!/usr/bin/env bats
# run-service runs a one-off container for an attached service; --pull pulls its image first.

load ../helpers

setup() {
    NAME="$(instance)"
    PETL_IMAGE_NAME=alpine PETL_IMAGE_TAG=3.21 PETL_MYSQL_PASSWORD=Pw-1 PETL_SQLSERVER_PASSWORD=Pw-1 \
        SERVICES=openmrs-db,petl create_instance "$NAME"
}
teardown() { destroy_instance "$NAME"; common_teardown; }

@test "run-service --pull pulls the service's image first, even a profiled one" {
    record_docker_argv
    run "$BIN/openmrs-docker" "$NAME" run-service --pull petl true
    assert_success
    run grep -E '^compose .* pull petl$' "$DOCKER_ARGV_LOG"
    assert_success
}

@test "run-service --pull needs a service" {
    run "$BIN/openmrs-docker" "$NAME" run-service --pull
    assert_failure
    assert_output --partial "usage:"
}
