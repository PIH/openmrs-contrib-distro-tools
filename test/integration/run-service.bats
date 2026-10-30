#!/usr/bin/env bats
# run-service runs a one-off container for a service. A service that holds the instance's lock (petl)
# is a job against the running instance: its setups run first, and nothing of the instance is
# started, stopped or recreated.

load ../helpers

# A stand-in for an ETL image: a line per run, then PETL_EXIT_CODE.
STUB_PETL_IMAGE=distro-tools-test/stub-petl
setup_file() {
    docker build -q -t "$STUB_PETL_IMAGE" - >/dev/null <<'DOCKERFILE'
FROM alpine:3.21
CMD ["sh", "-c", "echo PETL-RAN; exit ${PETL_EXIT_CODE:-0}"]
DOCKERFILE
}

setup() {
    NAME="$(instance)"
    PETL_IMAGE_NAME=alpine PETL_IMAGE_TAG=3.21 PETL_MYSQL_PASSWORD=Pw-1 PETL_SQLSERVER_PASSWORD=Pw-1 \
        create_instance "$NAME" --services=openmrs-db,petl
    DIR="$PIHX_HOME/$NAME"
}
teardown() { destroy_instance "$NAME"; remove_images "$NAME-"; common_teardown; }

running() { docker ps --format '{{.Names}}' --filter "label=com.docker.compose.project=$NAME" | sort; }

@test "a service that doesn't hold the lock leaves the instance's containers alone" {
    # a container of the instance's own, added by an override file
    cat > "$DIR/openmrs-db.override.yaml" <<'YAML'
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
    set_env_value "$NAME" openmrs-db OPENMRS_DB_OPT_max_allowed_packet 512M
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

petl_container() { docker ps -aq --filter "name=^$NAME-petl$"; }

@test "petl's own runs reuse one kept container: its log builds up across runs, and a run exits with PETL's exit code" {
    set_env_value "$NAME" petl PETL_IMAGE_NAME "$STUB_PETL_IMAGE"
    set_env_value "$NAME" petl PETL_IMAGE_TAG latest
    "$BIN/openmrs-docker" "$NAME" start >/dev/null 2>&1
    run "$BIN/openmrs-docker" "$NAME" run-service petl
    assert_success
    assert_output --partial 'PETL-RAN'
    local first
    first=$(petl_container)
    [ -n "$first" ] || fail "no kept petl container"
    run "$BIN/openmrs-docker" "$NAME" run-service petl
    assert_success
    assert_equal "$(petl_container)" "$first"
    run docker logs "$NAME-petl"
    assert_success
    assert_equal "$(grep -c PETL-RAN <<< "$output")" 2
    # A config change recreates it; the run's exit code is PETL's.
    echo "PETL_EXIT_CODE='3'" >> "$DIR/petl.env"
    run "$BIN/openmrs-docker" "$NAME" run-service petl
    assert_failure 3
    [ "$(petl_container)" != "$first" ] || fail "an env change didn't recreate the kept container"
    assert_equal "$(docker inspect -f '{{.State.ExitCode}}' "$NAME-petl")" 3
}

@test "stop removes petl's kept container, so the next run works; destroy removes petl's volume" {
    set_env_value "$NAME" petl PETL_IMAGE_NAME "$STUB_PETL_IMAGE"
    set_env_value "$NAME" petl PETL_IMAGE_TAG latest
    "$BIN/openmrs-docker" "$NAME" start >/dev/null 2>&1
    "$BIN/openmrs-docker" "$NAME" run-service petl >/dev/null 2>&1
    run "$BIN/openmrs-docker" "$NAME" stop
    assert_success
    assert_equal "$(petl_container)" ""
    "$BIN/openmrs-docker" "$NAME" start >/dev/null 2>&1
    run "$BIN/openmrs-docker" "$NAME" run-service petl
    assert_success
    assert_output --partial 'PETL-RAN'
    run docker volume ls -q --filter "name=^${NAME}_petl-data$"
    assert_output "${NAME}_petl-data"
    run "$BIN/openmrs-docker" "$NAME" destroy --force
    assert_success
    run docker volume ls -q --filter "name=^${NAME}_petl-data$"
    assert_output ''
    assert_equal "$(petl_container)" ""
}

@test "a petl run on a new image under the same tag removes the one it replaced" {
    local ref="$NAME-etl:latest" old_id
    printf 'FROM alpine:3.21\nRUN echo %s > /marker\nCMD ["true"]\n' "$NAME-one" | docker build -q -t "$ref" - >/dev/null
    set_env_value "$NAME" petl PETL_IMAGE_NAME "$NAME-etl"
    set_env_value "$NAME" petl PETL_IMAGE_TAG latest
    "$BIN/openmrs-docker" "$NAME" start >/dev/null 2>&1
    run "$BIN/openmrs-docker" "$NAME" run-service petl
    assert_success
    old_id=$(image_id "$ref")
    printf 'FROM alpine:3.21\nRUN echo %s > /marker\nCMD ["true"]\n' "$NAME-two" | docker build -q -t "$ref" - >/dev/null
    run "$BIN/openmrs-docker" "$NAME" run-service petl
    assert_success
    assert_output --partial "Removed the replaced image ${old_id#sha256:}"
    run docker image inspect "$old_id"
    assert_failure
}
