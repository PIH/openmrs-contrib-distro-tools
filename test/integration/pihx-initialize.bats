#!/usr/bin/env bats
# pihx initialize --from <folder> | --from-image <image>, black-box through bin/pihx: each service
# restores its own entry of the folder, named after it, through its manifest's restore overlays.
# The folders are under the test's directory, outside the paths the launcher always mounts.

load ../helpers

setup_file() {
    # A seed image as build-seeded-image.yml makes it: openmrs-db.sql.gz (marker 7) and openmrs.tar.gz
    # from backup-openmrs-data-directory, holding seed-only.txt and runtime properties.
    export SEED_IMAGE
    SEED_IMAGE="$(file_res seed)"
    local ctx="$BATS_FILE_TMPDIR/seed"
    mkdir -p "$ctx" "$BATS_FILE_TMPDIR/data/complex_obs"
    echo seed > "$BATS_FILE_TMPDIR/data/complex_obs/seed-only.txt"
    echo 'connection.username=openmrs' > "$BATS_FILE_TMPDIR/data/openmrs-runtime.properties"
    printf 'CREATE TABLE marker (id INT);\nINSERT INTO marker VALUES (7);\n' | gzip > "$ctx/openmrs-db.sql.gz"
    "$UTILS/backup-openmrs-data-directory.sh" --volume="$BATS_FILE_TMPDIR/data" \
        --output="$ctx/openmrs.tar.gz" 2>/dev/null
    docker build -q -t "$SEED_IMAGE" -f "$REPO_ROOT/openmrs/seed/Dockerfile" "$ctx" >/dev/null
}
teardown_file() {
    docker rmi -f "$SEED_IMAGE" >/dev/null 2>&1 || true
    common_teardown_file
}

setup() {
    cd "$BATS_TEST_TMPDIR"
    NAME="$(instance)"
    mkdir run
}
teardown() {
    "$BIN/pihx" "$NAME" destroy --force >/dev/null 2>&1 || true
    common_teardown
}

create() { # <service,...>
    "$BIN/pihx" "$NAME" create --services="$1" >/dev/null
}

# Capped, so a hung restore fails the test instead of waiting out initialize's own hour.
initialize() { # <args...>
    run timeout 300 "$BIN/pihx" "$NAME" initialize "$@"
}

volumes() { docker volume ls -q --filter "name=^${NAME}_" | sort; }
containers() { docker ps -aq --filter "label=com.docker.compose.project=$NAME"; }

# The data fixture's tree, with openmrs-runtime.properties moved aside by initialize.
RESTORED_TREE="${FIXTURE_TREE/.\/openmrs-runtime.properties/./openmrs-runtime.properties.restored}"

@test "initialize --from a folder with a dump and a data archive" {
    create openmrs-db,openmrs
    write_tiny_dump run/openmrs-db.sql
    make_data_fixture data
    ARCHIVE_PASSWORD=pw "$UTILS/backup-openmrs-data-directory.sh" --volume="$BATS_TEST_TMPDIR/data" \
        --output="$BATS_TEST_TMPDIR/run/openmrs.7z" 2>/dev/null
    ARCHIVE_PASSWORD=pw initialize --from "$BATS_TEST_TMPDIR/run"
    assert_success
    assert_output --partial "Initialized $NAME."
    assert_output --partial 'Moved openmrs-runtime.properties aside'
    assert_output --partial "Changed the owner of the restored openmrs-data to $OPENMRS_DATA_OWNER"
    run db_marker_in_volume "${NAME}_db-data"
    assert_output 1
    run tree_of_volume "${NAME}_openmrs-data"
    assert_output "$RESTORED_TREE"
    # No containers, and no staging volumes, are left; nor the password in any file.
    assert_equal "$(containers)" ""
    assert_equal "$(volumes)" "$(printf '%s\n' "${NAME}_db-data" "${NAME}_openmrs-data")"
    run grep -rl pw "$PIHX_HOME/$NAME"
    assert_failure
}

@test "a service without an entry starts empty" {
    create openmrs-db,openmrs
    # An entry may be a link to a file elsewhere: the host resolves it.
    mkdir elsewhere
    printf 'CREATE TABLE marker (id INT);\nINSERT INTO marker VALUES (3);\n' | gzip > elsewhere/dump.sql.gz
    ln -s "$BATS_TEST_TMPDIR/elsewhere/dump.sql.gz" run/openmrs-db.sql.gz
    initialize --from run
    assert_success
    run db_marker_in_volume "${NAME}_db-data"
    assert_output 3
    # openmrs-data is OpenMRS's to build up on its first start.
    assert_equal "$(volumes)" "${NAME}_db-data"
}

@test "an existing volume of a restoring service is refused, even one its restore doesn't name" {
    create openmrs-db,openmrs
    # A dump restore adds only a file to openmrs-db, which mounts db-data itself.
    docker volume create "${NAME}_db-data" >/dev/null
    write_tiny_dump run/openmrs-db.sql
    initialize --from run
    assert_failure
    assert_output --partial "${NAME}_db-data already exists"
    assert_equal "$(volumes)" "${NAME}_db-data"
}

@test "a dangling link entry is an error, not an empty restore" {
    create openmrs-db,openmrs
    ln -s "$BATS_TEST_TMPDIR/nosuch/dump.sql.gz" run/openmrs-db.sql.gz
    initialize --from run
    assert_failure
    assert_output --partial "run/openmrs-db.sql.gz doesn't exist on the host"
    assert_equal "$(volumes)" ""
    assert_equal "$(containers)" ""
    [ ! -e "$BATS_TEST_TMPDIR/nosuch" ] || fail "a directory was made for the missing entry"
}

@test "two entries for one service is an error" {
    create openmrs-db,openmrs
    write_tiny_dump run/openmrs-db.sql
    mkdir run/openmrs-db.datadir
    initialize --from run
    assert_failure
    assert_output --partial 'two entries for openmrs-db: openmrs-db.datadir and openmrs-db.sql'
    assert_equal "$(volumes)" ""
}

@test "an entry for a service the instance lacks is an error" {
    create openmrs-db
    write_tiny_dump run/openmrs-db.sql
    mkdir run/openmrs
    initialize --from run
    assert_failure
    assert_output --partial "run/openmrs is for openmrs, which isn't part of $NAME"
    echo x > run/notes.txt
    rmdir run/openmrs
    initialize --from run
    assert_failure
    assert_output --partial "run/notes.txt matches no service of $NAME"
    assert_equal "$(volumes)" ""
}

@test "a relative --from resolves against the caller's directory" {
    create openmrs-db,openmrs
    make_data_fixture run/openmrs
    mkdir elsewhere && cd elsewhere
    initialize --from ../run
    assert_success
    run tree_of_volume "${NAME}_openmrs-data"
    assert_output "$RESTORED_TREE"
    # Only openmrs had an entry: the database starts empty.
    assert_equal "$(volumes)" "${NAME}_openmrs-data"
}

@test "--from-image restores a seed" {
    create openmrs-db,openmrs
    initialize --from-image "$SEED_IMAGE"
    assert_success
    run db_marker_in_volume "${NAME}_db-data"
    assert_output 7
    run tree_of_volume "${NAME}_openmrs-data"
    assert_output "$(printf '%s\n' ./complex_obs ./complex_obs/seed-only.txt ./openmrs-runtime.properties.restored)"
    # The copy of the seed's folder is gone; a seed image that was here before is kept.
    assert_equal "$(find "$PIHX_HOME" "$PIHX_HOME/$NAME" -maxdepth 1 -name "*seed-*")" ""
    [ -n "$(image_id "$SEED_IMAGE")" ] || fail "the seed image, here before initialize, was removed"
}

@test "--from-image with a seed it can't restore says what the seed holds" {
    local ctx="$BATS_TEST_TMPDIR/old-seed" image
    image="$(res old-seed)"
    mkdir -p "$ctx"
    write_tiny_dump "$ctx/dump.sql" && gzip "$ctx/dump.sql"
    tar czf "$ctx/data.tar.gz" -C "$BATS_FILE_TMPDIR/data" .
    printf 'FROM alpine:3.21\nCOPY dump.sql.gz data.tar.gz /seed/\n' > "$ctx/Dockerfile"
    docker build -q -t "$image" "$ctx" >/dev/null
    create openmrs-db,openmrs
    initialize --from-image "$image"
    docker rmi -f "$image" >/dev/null
    assert_failure
    assert_output --partial "error: $image isn't a seed this version restores: its /seed holds data.tar.gz, dump.sql.gz"
    # What an OpenMRS seed it can't restore probably is, openmrs-docker says (openmrs/extension.py).
    refute_output --partial "openmrs/seed/Dockerfile"
    refute_output --partial "$PIHX_HOME/."
    refute_output --partial "/.seed-"
    assert_equal "$(find "$PIHX_HOME" "$PIHX_HOME/$NAME" -maxdepth 1 -name "*seed-*")" ""
    assert_equal "$(volumes)" ""
}

@test "a failed restore leaves no volumes" {
    create openmrs-db,openmrs
    write_tiny_dump run/openmrs-db.sql
    make_data_fixture data
    ARCHIVE_PASSWORD=pw "$UTILS/backup-openmrs-data-directory.sh" --volume="$BATS_TEST_TMPDIR/data" \
        --output="$BATS_TEST_TMPDIR/run/openmrs.7z" 2>/dev/null
    ARCHIVE_PASSWORD=wrong initialize --from run
    assert_failure
    assert_output --partial 'Wrong password'
    assert_output --partial 'initialize failed'
    assert_equal "$(volumes)" ""
    assert_equal "$(containers)" ""
}

@test "openmrs' prepare gives the restored openmrs-data to the user its image runs as" {
    OPENMRS_IMAGE_NAME=alpine OPENMRS_IMAGE_TAG=3.21 create openmrs-db,openmrs
    make_data_fixture run/openmrs
    OPENMRS_DATA_OWNER= initialize --from run
    assert_success
    assert_output --partial 'Changed the owner of the restored openmrs-data to 0:0'
}

@test "a failing prepare is an error naming the service and hook, before any volume exists" {
    create openmrs-db,openmrs
    make_data_fixture run/openmrs
    # placeholder/openmrs can't be run to find its user.
    OPENMRS_DATA_OWNER= initialize --from run
    assert_failure
    assert_output --partial 'set OPENMRS_DATA_OWNER=<uid>:<gid>'
    assert_output --partial 'error: openmrs: restore/prepare failed'
    assert_equal "$(volumes)" ""
}
