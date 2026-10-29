#!/usr/bin/env bats
# initialize from a seed image (each volume, or both), its timeout, and reset-openmrs-db-accounts on
# an instance without openmrs-data.

load ../helpers

# Seed images as build-seeded-image.yml makes them, from openmrs/seed/Dockerfile: openmrs-db.sql.gz
# with marker 7, and openmrs.tar.gz from backup-openmrs-data-directory holding seed-only.txt and
# runtime properties (in one data/ folder). FLAT_SEED_IMAGE's openmrs.tar.gz is flat.
setup_file() {
    export SEED_IMAGE="$(file_res seed)" FLAT_SEED_IMAGE="$(file_res flat-seed)"
    local ctx="$BATS_FILE_TMPDIR/seed" flat="$BATS_FILE_TMPDIR/flat-seed"
    mkdir -p "$ctx" "$BATS_FILE_TMPDIR/data/complex_obs"
    echo seed > "$BATS_FILE_TMPDIR/data/complex_obs/seed-only.txt"
    echo 'connection.username=openmrs' > "$BATS_FILE_TMPDIR/data/openmrs-runtime.properties"
    printf 'CREATE TABLE marker (id INT);\nINSERT INTO marker VALUES (7);\n' | gzip > "$ctx/openmrs-db.sql.gz"
    "$UTILS/backup-openmrs-data-directory.sh" --volume="$BATS_FILE_TMPDIR/data" --output="$ctx/openmrs.tar.gz" 2>/dev/null
    cp -r "$ctx" "$flat"
    tar czf "$flat/openmrs.tar.gz" -C "$BATS_FILE_TMPDIR/data" .
    docker build -q -t "$SEED_IMAGE" -f "$REPO_ROOT/openmrs/seed/Dockerfile" "$ctx" >/dev/null
    docker build -q -t "$FLAT_SEED_IMAGE" -f "$REPO_ROOT/openmrs/seed/Dockerfile" "$flat" >/dev/null
}
# The seed's tree, with openmrs-runtime.properties moved aside by initialize (it holds the source's
# connection settings).
SEED_DATA_TREE="$(printf '%s\n' ./complex_obs ./complex_obs/seed-only.txt ./openmrs-runtime.properties.restored)"

# The seeded openmrs-data's root belongs to the user OpenMRS runs as (OPENMRS_DATA_OWNER, here the
# test runner's ids), who must be able to write there (e.g. a new openmrs-runtime.properties).
assert_seeded_root_owner() {
    run docker run --rm -v "${NAME}_openmrs-data:/d:ro" alpine:3.21 stat -c %u:%g "/d"
    assert_output "$OPENMRS_DATA_OWNER"
    run docker run --rm -v "${NAME}_openmrs-data:/d:ro" alpine:3.21 stat -c %A "/d"
    assert_output --regexp '^d.w'
}

teardown_file() {
    docker rmi -f "$SEED_IMAGE" "$FLAT_SEED_IMAGE" >/dev/null 2>&1 || true
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

# SEED_IMAGE_NAME at create: initialize reads it from the instance's instance.env, which wins over
# the shell.
create_seeded() { SEED_IMAGE_NAME="$SEED_IMAGE" SERVICES=openmrs-db,openmrs create_instance "$NAME"; }

@test "initialize fills both volumes from a seed image" {
    create_seeded
    run_initialize "$NAME"
    assert_success
    run db_marker_in_volume "${NAME}_db-data"
    assert_output 7
    run tree_of_volume "${NAME}_openmrs-data"
    assert_output "$SEED_DATA_TREE"
    assert_seeded_root_owner
    # A seed image that was here before initialize is kept.
    refute_output --partial 'pulled for this command'
    [ -n "$(image_id "$SEED_IMAGE")" ] || fail "the seed image, here before initialize, was removed"
}

@test "initialize removes a seed image it pulled" {
    local seed
    start_registry "$NAME-registry"
    seed="$REGISTRY/$NAME-seed:t"
    docker tag "$SEED_IMAGE" "$seed" && docker push -q "$seed" >/dev/null && docker rmi "$seed" >/dev/null
    SEED_IMAGE_NAME="${seed%:t}" SEED_IMAGE_TAG=t SERVICES=openmrs-db,openmrs create_instance "$NAME"
    run_initialize "$NAME"
    assert_success
    assert_output --partial "Removed $seed, pulled for this command"
    [ -z "$(image_id "$seed")" ] || fail "$seed, pulled by initialize, is still there"
    run db_marker_in_volume "${NAME}_db-data"
    assert_output 7
}

@test "a seed image with a flat openmrs.tar.gz still fills openmrs-data" {
    SEED_IMAGE_NAME="$FLAT_SEED_IMAGE" SERVICES=openmrs-db,openmrs create_instance "$NAME"
    run_initialize "$NAME"
    assert_success
    run tree_of_volume "${NAME}_openmrs-data"
    assert_output "$SEED_DATA_TREE"
    assert_seeded_root_owner
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
    assert_output "$SEED_DATA_TREE"
}

@test "initialize gives up after INITIALIZE_DB_TIMEOUT, and leaves no containers or restore volumes" {
    SERVICES=openmrs-db create_instance "$NAME"
    # Keeps MySQL's first-boot import, and so its healthcheck, busy past the timeout.
    printf 'SELECT SLEEP(120);\n' > dump.sql
    run_initialize "$NAME" RESTORE_MYSQL_DUMP_PATH=dump.sql INITIALIZE_DB_TIMEOUT=5
    assert_failure
    assert_output --partial 'timed out after 5s'
    assert_output --partial "initialize failed"
    assert_equal "$(docker ps -aq --filter "label=com.docker.compose.project=$NAME")" ""
    run docker volume inspect "${NAME}_db-init"
    assert_failure
    # nothing to destroy before retrying
    assert_equal "$(docker volume ls -q --filter "label=com.docker.compose.project=$NAME")" ""
}

@test "reset-openmrs-db-accounts works on an instance with no openmrs-data volume" {
    SERVICES=openmrs-db create_instance "$NAME"
    write_tiny_dump dump.sql
    run_initialize "$NAME" RESTORE_MYSQL_DUMP_PATH=dump.sql
    assert_success
    set_env_value "$NAME" openmrs-db OPENMRS_DB_PASSWORD rotated-pw
    run "$BIN/openmrs-docker" "$NAME" reset-openmrs-db-accounts
    assert_success
    assert_output --partial "Set the password of openmrs@%"
    refute_output --partial "openmrs-runtime.properties"
    wait_for_mysql "$NAME-openmrs-db" openmrs rotated-pw
}
