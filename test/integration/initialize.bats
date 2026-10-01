#!/usr/bin/env bats
# initialize from a seed image (each volume, or both), its timeout, and reset-openmrs-db-accounts on
# an instance without openmrs-data.

load ../helpers

# A seed image as build-seeded-image.yml makes one, from docker/Dockerfile.seed: a dump with
# marker 7, and a flat data.tar.gz holding seed-only.txt.
setup_file() {
    export SEED_IMAGE="$(file_res seed)"
    local ctx="$BATS_FILE_TMPDIR/seed"
    mkdir -p "$ctx/data/complex_obs"
    echo seed > "$ctx/data/complex_obs/seed-only.txt"
    printf 'CREATE TABLE marker (id INT);\nINSERT INTO marker VALUES (7);\n' | gzip > "$ctx/dump.sql.gz"
    tar czf "$ctx/data.tar.gz" -C "$ctx/data" .
    cp "$REPO_ROOT/docker/seed-entrypoint.sh" "$ctx/"
    docker build -q -t "$SEED_IMAGE" -f "$REPO_ROOT/docker/Dockerfile.seed" "$ctx" >/dev/null
}
teardown_file() {
    docker rmi -f "$SEED_IMAGE" >/dev/null 2>&1 || true
    common_teardown_file
}

setup() {
    cd "$BATS_TEST_TMPDIR"
    NAME="$(instance)"
}
teardown() {
    destroy_instance "$NAME"
    common_teardown
}

# SEED_IMAGE_NAME at create: initialize reads it from the instance's env, which wins over the shell.
create_seeded() { SEED_IMAGE_NAME="$SEED_IMAGE" SERVICES=openmrs-db,openmrs create_instance "$NAME"; }

@test "initialize fills both volumes from a seed image" {
    create_seeded
    run_initialize "$NAME"
    assert_success
    run db_marker_in_volume "${NAME}_db-data"
    assert_output 7
    run tree_of_volume "${NAME}_openmrs-data"
    assert_output "$(printf './complex_obs\n./complex_obs/seed-only.txt')"
    # A seeded openmrs-data has its runtime properties, so OpenMRS knows the tables exist.
    run grep -c '^OPENMRS_CREATE_TABLES=' "$OPENMRS_DOCKER_HOME/$NAME/env"
    assert_output 0
}

@test "initialize takes db-data from the seed image and openmrs-data from a directory" {
    create_seeded
    mkdir -p data/complex_obs && echo restored > data/complex_obs/restored.txt
    run_initialize "$NAME" RESTORE_OPENMRS_DATA_PATH=data
    assert_success
    run db_marker_in_volume "${NAME}_db-data"
    assert_output 7
    run tree_of_volume "${NAME}_openmrs-data"
    assert_output "$(printf './complex_obs\n./complex_obs/restored.txt')"
}

@test "initialize takes openmrs-data from the seed image and db-data from a dump" {
    create_seeded
    write_tiny_dump dump.sql
    run_initialize "$NAME" RESTORE_MYSQL_DUMP_PATH=dump.sql
    assert_success
    run db_marker_in_volume "${NAME}_db-data"
    assert_output 1
    run tree_of_volume "${NAME}_openmrs-data"
    assert_output "$(printf './complex_obs\n./complex_obs/seed-only.txt')"
}

@test "initialize gives up after INITIALIZE_DB_TIMEOUT, and leaves no containers or restore volumes" {
    SERVICES=openmrs-db create_instance "$NAME"
    # Keeps MySQL's first-boot import, and so its healthcheck, busy past the timeout.
    printf 'SELECT SLEEP(120);\n' > dump.sql
    run_initialize "$NAME" RESTORE_MYSQL_DUMP_PATH=dump.sql INITIALIZE_DB_TIMEOUT=5
    assert_failure
    assert_output --partial 'timed out after 5s'
    assert_output --partial "initialize failed -- run"
    assert_equal "$(docker ps -aq --filter "label=com.docker.compose.project=$NAME")" ""
    run docker volume inspect "${NAME}_db-init"
    assert_failure
}

@test "reset-openmrs-db-accounts works on an instance with no openmrs-data volume" {
    SERVICES=openmrs-db create_instance "$NAME"
    write_tiny_dump dump.sql
    run_initialize "$NAME" RESTORE_MYSQL_DUMP_PATH=dump.sql
    assert_success
    sed -i "s/^OPENMRS_DB_PASSWORD=.*/OPENMRS_DB_PASSWORD='rotated-pw'/" "$OPENMRS_DOCKER_HOME/$NAME/env"
    run "$BIN/openmrs-docker" "$NAME" reset-openmrs-db-accounts
    assert_success
    assert_output --partial "Set the password of openmrs@%"
    refute_output --partial "openmrs-runtime.properties"
    wait_for_mysql "$NAME-openmrs-db" openmrs rotated-pw
}
