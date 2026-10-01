#!/usr/bin/env bats
# start, wait, status, restart, stop, pull, update, and the drift warning and sync, against a stub
# OpenMRS image (see build_stub_openmrs_image).

load ../helpers

setup_file() { build_stub_openmrs_image; }

setup() {
    cd "$BATS_TEST_TMPDIR"
    NAME="$(instance)"
    DIR="$OPENMRS_DOCKER_HOME/$NAME"
}
teardown() {
    destroy_instance "$NAME"
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
    assert_output --partial 'OpenMRS is ready.'
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

@test "wait fails as soon as OpenMRS exits, rather than waiting out its timeout" {
    OMRS_EXTRA_stub_exit=1 create_with_stub
    "$BIN/openmrs-docker" "$NAME" start >/dev/null 2>&1
    run timeout 120 "$BIN/openmrs-docker" "$NAME" wait
    assert_failure
    # Docker restarts it (restart: unless-stopped), so wait may see it exited or its healthcheck failed
    assert_output --regexp 'exited unexpectedly|reported unhealthy'
    assert_output --partial 'OpenMRS did not become ready'
}

@test "start notes a fragment that differs from the tool's; sync restores it, and update then starts quietly" {
    SERVICES=openmrs-db create_instance "$NAME"
    echo '# changed by hand' >> "$DIR/openmrs-db.yaml"
    run "$BIN/openmrs-docker" "$NAME" start
    assert_success
    assert_output --partial 'newer service definitions available for: openmrs-db.yaml'
    run "$BIN/openmrs-docker" "$NAME" sync
    assert_success
    assert_output --partial 'Synced openmrs-db.yaml'
    cmp "$DIR/openmrs-db.yaml" "$REPO_ROOT/docker/services/openmrs-db.yaml"
    run "$BIN/openmrs-docker" "$NAME" update
    assert_success
    refute_output --partial 'newer service definitions'
    assert_equal "$(running)" "$NAME-openmrs-db"
}

@test "pull fetches the instance's images without starting anything" {
    SERVICES=openmrs-db create_instance "$NAME"
    run "$BIN/openmrs-docker" "$NAME" pull
    assert_success
    assert_equal "$(running)" ""
}
