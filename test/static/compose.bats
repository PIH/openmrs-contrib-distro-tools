#!/usr/bin/env bats
# Every Compose fragment and overlay is valid Compose, interpolated against the env file `create`
# actually writes -- catches broken YAML, bad `$` escaping in inline scripts, and depends_on
# references to services that don't exist in the combination initialize/start use.

load ../helpers

setup_file() {
    export ALL_SERVICES
    ALL_SERVICES=$(cd "$REPO_ROOT/docker/services" && ls ./*.yaml | xargs -n1 basename | sed 's/\.yaml$//' | paste -sd, -)
    export CONFIG_INSTANCE="$RUN_PREFIX-f-compose"
    SERVICES="$ALL_SERVICES" create_instance "$CONFIG_INSTANCE"
}

teardown_file() {
    rm -rf "${OPENMRS_DOCKER_HOME:?}/$CONFIG_INSTANCE"
}

# Validates the instance's fragments plus any extra overlay files.
compose_config() { # [overlay...]
    local dir="$OPENMRS_DOCKER_HOME/$CONFIG_INSTANCE" args=() f
    for f in "$dir"/*.yaml; do args+=(-f "$f"); done
    for f in "$@"; do args+=(-f "$REPO_ROOT/docker/modes/$f"); done
    # Placeholders for the vars initialize sets itself for the overlays that need them.
    run env SEED_IMAGE_NAME=placeholder/seed \
        RESTORE_MYSQL_DUMP_PATH=/tmp/dump.sql RESTORE_MYSQL_DUMP_FILENAME=dump.sql \
        RESTORE_MYSQL_DUMP_ARCHIVE_FILENAME=archive.7z \
        RESTORE_MYSQL_DATA_PATH=/tmp/datadir \
        RESTORE_OPENMRS_DATA_PATH=/tmp/data RESTORE_OPENMRS_DATA_ARCHIVE_FILENAME=archive.tar.gz \
        docker compose --env-file "$dir/env" "${args[@]}" config -q
}

# A variable Compose can't resolve is only a warning (blanked, exit 0) -- but for these files it
# always means an inline script's `$VAR` that should have been escaped as `$$VAR`.
assert_valid() {
    assert_success
    refute_output --partial 'variable is not set'
}

@test "every service fragment together is valid" {
    compose_config
    assert_valid
}

@test "dev mode overlay is valid" {
    # --dev requires DISTRO_SOURCE_DIR (openmrs-docker enforces the same before using dev.yaml).
    DISTRO_SOURCE_DIR=/tmp/distro compose_config dev.yaml
    assert_valid
}

@test "restore-mysql-volume-from-dump overlay is valid" {
    compose_config restore-mysql-volume-from-dump.yaml
    assert_valid
}

@test "restore-mysql-volume-from-dump-archive overlay is valid" {
    compose_config restore-mysql-volume-from-dump-archive.yaml
    assert_valid
}

@test "restore-mysql-volume-from-data-dir overlay is valid" {
    compose_config restore-mysql-volume-from-data-dir.yaml
    assert_valid
}

@test "restore-mysql-volume-from-seed overlay is valid" {
    compose_config restore-mysql-volume-from-seed.yaml
    assert_valid
}

@test "restore-openmrs-data-volume-from-backup overlay is valid" {
    compose_config restore-openmrs-data-volume-from-backup.yaml
    assert_valid
}

@test "restore-openmrs-data-volume-from-archive overlay is valid" {
    compose_config restore-openmrs-data-volume-from-archive.yaml
    assert_valid
}

@test "restore-openmrs-data-volume-from-seed overlay is valid" {
    compose_config restore-openmrs-data-volume-from-seed.yaml
    assert_valid
}

@test "seed overlays for both volumes combine" {
    compose_config restore-mysql-volume-from-seed.yaml restore-openmrs-data-volume-from-seed.yaml
    assert_valid
}

@test "an OMRS_EXTRA_* variable set at create time reaches the openmrs service's resolved config" {
    local name="$RUN_PREFIX-f-compose-extra" dir
    OMRS_EXTRA_pihmalawi_warehouse_connection_url="jdbc:mysql://openmrs-db:3306/openmrs_warehouse" \
        SERVICES=openmrs-db,openmrs create_instance "$name"
    dir="$OPENMRS_DOCKER_HOME/$name"
    run docker compose --env-file "$dir/env" -f "$dir/openmrs-db.yaml" -f "$dir/openmrs.yaml" config
    assert_success
    assert_output --partial 'OMRS_EXTRA_pihmalawi_warehouse_connection_url: jdbc:mysql://openmrs-db:3306/openmrs_warehouse'
    rm -rf "$dir"
}
