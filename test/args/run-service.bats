#!/usr/bin/env bats
# run-service runs a one-off container for an attached service; --pull pulls its image first.

load ../helpers

setup() {
    NAME="$(instance)"
    PETL_IMAGE_NAME=alpine PETL_IMAGE_TAG=3.21 PETL_MYSQL_PASSWORD=Pw-1 PETL_SQLSERVER_PASSWORD=Pw-1 \
        create_instance "$NAME" --services=openmrs-db,petl
}
teardown() { remove_test_instance "$NAME"; common_teardown; }

@test "run-service --pull pulls the service's image first, even a profiled one" {
    # A container that doesn't hold the lock, so nothing else of the instance is involved, added by
    # an override file (the instance's own Compose additions).
    printf 'services:\n  job:\n    image: alpine:3.21\n    profiles: ["job"]\n' > "$PIHX_HOME/$NAME/openmrs-db.override.yaml"
    run "$BIN/openmrs-docker" "$NAME" run-service --pull job true
    assert_success
    # Compose's pull runs in pihx's container, so its output, not a host command line, shows it
    assert_output --regexp 'job[[:space:]]+Pulled'
}

@test "run-service --pull needs a service" {
    run "$BIN/openmrs-docker" "$NAME" run-service --pull
    assert_failure
    assert_output --partial "usage:"
}
