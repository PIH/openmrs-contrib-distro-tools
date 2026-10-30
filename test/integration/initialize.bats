#!/usr/bin/env bats
# openmrs-docker initialize --from-image (pihx's, and the extension's hint for an old seed), its
# timeout, and openmrs-db reset-accounts on an instance without openmrs-data.

load ../helpers

# Seed images as build-seeded-image.yml makes them, from openmrs/seed/Dockerfile: openmrs-db.sql.gz
# with marker 7, and openmrs.tar.gz from backup-openmrs-data-directory holding seed-only.txt and
# runtime properties (in one data/ directory). FLAT_SEED_IMAGE's openmrs.tar.gz is flat.
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
    remove_test_instance "$NAME"
    common_teardown
}

create_openmrs() { create_instance "$NAME" --services=openmrs-db,openmrs; }

@test "initialize fills both volumes from a seed image" {
    create_openmrs
    run_initialize "$NAME" --from-image "$SEED_IMAGE"
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
    create_openmrs
    run_initialize "$NAME" --from-image "$seed"
    assert_success
    assert_output --partial "Removed $seed, pulled for this command"
    [ -z "$(image_id "$seed")" ] || fail "$seed, pulled by initialize, is still there"
    run db_marker_in_volume "${NAME}_db-data"
    assert_output 7
}

@test "a seed image with a flat openmrs.tar.gz still fills openmrs-data" {
    create_openmrs
    run_initialize "$NAME" --from-image "$FLAT_SEED_IMAGE"
    assert_success
    run tree_of_volume "${NAME}_openmrs-data"
    assert_output "$SEED_DATA_TREE"
    assert_seeded_root_owner
}

@test "a seed pihx can't restore is named as probably an old-format one" {
    local ctx="$BATS_TEST_TMPDIR/old-seed" image
    image="$(res old-seed)"
    mkdir -p "$ctx"
    write_tiny_dump "$ctx/dump.sql" && gzip "$ctx/dump.sql"
    printf 'FROM alpine:3.21\nCOPY dump.sql.gz /seed/\n' > "$ctx/Dockerfile"
    docker build -q -t "$image" "$ctx" >/dev/null
    create_openmrs
    run_initialize "$NAME" --from-image "$image"
    docker rmi -f "$image" >/dev/null
    assert_failure
    assert_output --partial "isn't a seed this version restores"
    assert_output --partial "It's probably an old-format seed"
}

@test "initialize gives up after PIHX_INITIALIZE_TIMEOUT, and leaves no containers or restore volumes" {
    create_instance "$NAME" --services=openmrs-db
    # Keeps MySQL's first-boot import, and so its healthcheck, busy past the timeout.
    printf 'SELECT SLEEP(120);\n' > dump.sql
    PIHX_INITIALIZE_TIMEOUT=5 run_initialize "$NAME" --from "$(from_folder openmrs-db.sql dump.sql)"
    assert_failure
    assert_output --partial 'timed out after 5s'
    assert_output --partial "initialize failed"
    assert_equal "$(docker ps -aq --filter "label=com.docker.compose.project=$NAME")" ""
    run docker volume inspect "${NAME}_db-init"
    assert_failure
    # nothing to destroy before retrying
    assert_equal "$(docker volume ls -q --filter "label=com.docker.compose.project=$NAME")" ""
}

@test "openmrs-db reset-accounts works on an instance with no openmrs-data volume" {
    create_instance "$NAME" --services=openmrs-db
    write_tiny_dump dump.sql
    run_initialize "$NAME" --from "$(from_folder openmrs-db.sql dump.sql)"
    assert_success
    set_env_value "$NAME" openmrs-db OPENMRS_DB_PASSWORD rotated-pw
    run "$BIN/openmrs-docker" "$NAME" openmrs-db reset-accounts
    assert_success
    assert_output --partial "Set the password of openmrs@%"
    refute_output --partial "openmrs-runtime.properties"
    wait_for_mysql "$NAME-openmrs-db" openmrs rotated-pw
}
