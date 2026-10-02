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
    # A service that doesn't hold the lock, so nothing else of the instance is involved.
    printf 'name: ${SERVICE_NAME:?SERVICE_NAME must be set}\nservices:\n  job:\n    image: alpine:3.21\n    profiles: ["job"]\n' > "$OPENMRS_DOCKER_HOME/$NAME/job.yaml"
    record_docker_argv
    run "$BIN/openmrs-docker" "$NAME" run-service --pull job true
    assert_success
    run grep -E '^compose .* pull job$' "$DOCKER_ARGV_LOG"
    assert_success
}

@test "run-service --pull needs a service" {
    run "$BIN/openmrs-docker" "$NAME" run-service --pull
    assert_failure
    assert_output --partial "usage:"
}
