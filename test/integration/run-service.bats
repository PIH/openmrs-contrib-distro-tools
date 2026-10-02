#!/usr/bin/env bats
# run-service runs a one-off container for a service. A service that holds the instance's lock (petl)
# is a job against the running instance: its setups run first, and nothing of the instance is
# started, stopped or recreated.

load ../helpers

setup() {
    NAME="$(instance)"
    PETL_IMAGE_NAME=alpine PETL_IMAGE_TAG=3.21 PETL_MYSQL_PASSWORD=Pw-1 PETL_SQLSERVER_PASSWORD=Pw-1 \
        SERVICES=openmrs-db,petl create_instance "$NAME"
    DIR="$OPENMRS_DOCKER_HOME/$NAME"
}
teardown() { destroy_instance "$NAME"; common_teardown; }

running() { docker ps --format '{{.Names}}' --filter "label=com.docker.compose.project=$NAME" | sort; }

@test "a service that doesn't hold the lock leaves the instance's containers alone" {
    cat > "$DIR/job.yaml" <<'YAML'
name: ${SERVICE_NAME:?SERVICE_NAME must be set}
services:
  job:
    image: alpine:3.21
    profiles: ["job"]
YAML
    run "$BIN/openmrs-docker" "$NAME" run-service job echo JOB-RAN
    assert_success
    assert_output --partial 'JOB-RAN'
    assert_equal "$(running)" ""
}

@test "a lock-holding run runs the setups but doesn't recreate openmrs-db after an env change" {
    "$BIN/openmrs-docker" "$NAME" start >/dev/null 2>&1
    local before
    before=$(docker inspect -f '{{.Id}}' "$NAME-openmrs-db")
    sed -i "s/^OPENMRS_DB_OPT_max_allowed_packet=.*/OPENMRS_DB_OPT_max_allowed_packet='512M'/" "$DIR/env"
    run "$BIN/openmrs-docker" "$NAME" run-service petl echo PETL-RAN
    assert_success
    assert_output --partial 'Set the password of petl@%'   # the setup ran (start created the account)
    assert_output --partial 'PETL-RAN'
    assert_equal "$(docker inspect -f '{{.Id}}' "$NAME-openmrs-db")" "$before"
}

@test "a lock-holding run on a stopped instance fails at its setups, and the service doesn't run" {
    run "$BIN/openmrs-docker" "$NAME" run-service petl echo PETL-RAN
    assert_failure
    assert_output --partial 'openmrs-db-accounts failed'
    refute_output --partial 'PETL-RAN'
    assert_equal "$(running)" ""
}
