#!/usr/bin/env bats
# Every Compose fragment and overlay is valid Compose, interpolated against the env file `create`
# actually writes -- catches broken YAML, bad `$` escaping in inline scripts, and depends_on
# references to services that don't exist in the combination initialize/start use.

load ../helpers

setup_file() {
    export ALL_SERVICES
    ALL_SERVICES=$(cd "$REPO_ROOT/docker/services" && ls ./*.yaml | xargs -n1 basename | sed 's/\.yaml$//' | paste -sd, -)
    export CONFIG_INSTANCE="$(file_res config)"
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
        RESTORE_MYSQL_DATA_PATH=/tmp/datadir DISTRO_TOOLS_UTILS_DIR="$REPO_ROOT/utils" \
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

@test "restore-mysql-volume-from-data-dir overlay is valid, with reset-mysql-accounts" {
    compose_config restore-mysql-volume-from-data-dir.yaml reset-mysql-accounts.yaml
    assert_valid
}

@test "restore-mysql-volume-from-percona overlay is valid, with reset-mysql-accounts" {
    RESTORE_MYSQL_PERCONA_PATH=/tmp/percona.7z RESTORE_MYSQL_PERCONA_NAME=archive.7z \
        compose_config restore-mysql-volume-from-percona.yaml reset-mysql-accounts.yaml
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
    local name="$(file_res extra)" dir
    OMRS_EXTRA_pihmalawi_warehouse_connection_url="jdbc:mysql://openmrs-db:3306/openmrs_warehouse" \
        SERVICES=openmrs-db,openmrs create_instance "$name"
    dir="$OPENMRS_DOCKER_HOME/$name"
    run docker compose --env-file "$dir/env" -f "$dir/openmrs-db.yaml" -f "$dir/openmrs.yaml" config
    assert_success
    assert_output --partial 'OMRS_EXTRA_pihmalawi_warehouse_connection_url: jdbc:mysql://openmrs-db:3306/openmrs_warehouse'
    rm -rf "$dir"
}

@test "openmrs service sets pih_config under the image's own OMRS_EXTRA_ name, so it overrides the image default" {
    local name="$(file_res pihconfig)" dir
    OPENMRS_PIH_CONFIG="haiti,haiti-test" SERVICES=openmrs-db,openmrs create_instance "$name"
    dir="$OPENMRS_DOCKER_HOME/$name"
    run docker compose --env-file "$dir/env" -f "$dir/openmrs-db.yaml" -f "$dir/openmrs.yaml" config
    assert_success
    assert_output --partial 'OMRS_EXTRA_pih_config: haiti,haiti-test'
    refute_output --partial 'OMRS_EXTRA_PIH_CONFIG'
    rm -rf "$dir"
}

@test "openhim-core runs an init process, so zombie ssl_client processes from its healthcheck are reaped" {
    # BusyBox wget spawns an ssl_client helper per HTTPS request. When wget exits, the helper is
    # reparented to the container's PID 1 -- in openhim-core that's Node, which never reaps it.
    # Each zombie pins a seccomp filter's BPF JIT memory until the host can't load new filters.
    local dir="$OPENMRS_DOCKER_HOME/$CONFIG_INSTANCE" args=() f
    for f in "$dir"/*.yaml; do args+=(-f "$f"); done
    run docker compose --env-file "$dir/env" "${args[@]}" config openhim-core
    assert_success
    assert_output --partial 'init: true'
}

@test "openmrs-db gets its OPENMRS_DB_OPT_* server options from the env file" {
    local dir="$OPENMRS_DOCKER_HOME/$CONFIG_INSTANCE"
    run docker compose --env-file "$dir/env" -f "$dir/openmrs-db.yaml" config openmrs-db
    assert_success
    assert_output --partial 'OPENMRS_DB_OPT_character_set_server: utf8'
    assert_output --partial 'OPENMRS_DB_OPT_max_allowed_packet: 1G'
    refute_output --partial 'log_bin:'
}

@test "fragments take their defaults only from .env.defaults: each required variable has one, none repeats it" {
    local defaults required repeated missing
    defaults=$(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$REPO_ROOT"/docker/services/*.env.defaults | sort -u)
    required=$(grep -ho '\${[A-Za-z_][A-Za-z0-9_]*?' "$REPO_ROOT"/docker/services/*.yaml "$REPO_ROOT"/docker/modes/*.yaml \
        | sed 's/^\${//; s/?$//' | sort -u)
    repeated=$(grep -ho '\${[A-Za-z_][A-Za-z0-9_]*:-' "$REPO_ROOT"/docker/services/*.yaml "$REPO_ROOT"/docker/modes/*.yaml \
        | sed 's/^\${//; s/:-$//' | sort -u | comm -12 - <(echo "$defaults"))
    missing=$(comm -23 <(echo "$required") <(echo "$defaults"))
    [ -z "$repeated" ] || fail "yaml default repeats .env.defaults (use \${VAR?}): $repeated"
    [ -z "$missing" ] || fail "\${VAR?} with no .env.defaults entry: $missing"
}
