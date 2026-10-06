#!/usr/bin/env bats
# Every Compose fragment and overlay is valid Compose, interpolated against the env file `create`
# actually writes -- catches broken YAML, bad `$` escaping in inline scripts, and depends_on
# references to services that don't exist in the combination initialize/start use.

load ../helpers

setup_file() {
    export ALL_SERVICES
    ALL_SERVICES=$(cd "$REPO_ROOT/docker/services" && ls ./*.yaml | xargs -n1 basename | sed 's/\.yaml$//' | paste -sd, -)
    export CONFIG_INSTANCE="$(file_res config)"
    export PETL_SQLSERVER_PASSWORD=Placeholder-1 SQLSERVER_SA_PASSWORD=Placeholder-1 PETL_MYSQL_PASSWORD=Placeholder-1
    export ADVAPACS_GATEWAY_REGION=placeholder-region ADVAPACS_GATEWAY_ACCESS_KEY_ID=placeholder-id \
        ADVAPACS_GATEWAY_ACCESS_KEY_SECRET=placeholder-secret
    export MODALITY_SIMULATOR_GATEWAY_AE=PLACEHOLDER_GW
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
        P7ZIP_IMAGE=placeholder/p7zip PERCONA_IMAGE=placeholder/percona \
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
    defaults=$(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$REPO_ROOT"/docker/services/*.env.defaults \
        "$REPO_ROOT"/docker/instance.env.defaults | sort -u)
    required=$(grep -ho '\${[A-Za-z_][A-Za-z0-9_]*?' "$REPO_ROOT"/docker/services/*.yaml "$REPO_ROOT"/docker/modes/*.yaml \
        | sed 's/^\${//; s/?$//' | sort -u)
    repeated=$(grep -ho '\${[A-Za-z_][A-Za-z0-9_]*:-' "$REPO_ROOT"/docker/services/*.yaml "$REPO_ROOT"/docker/modes/*.yaml \
        | sed 's/^\${//; s/:-$//' | sort -u | comm -12 - <(echo "$defaults"))
    missing=$(comm -23 <(echo "$required") <(echo "$defaults"))
    [ -z "$repeated" ] || fail "yaml default repeats .env.defaults (use \${VAR?}): $repeated"
    [ -z "$missing" ] || fail "\${VAR?} with no .env.defaults entry: $missing"
}

@test "every variable a fragment or overlay uses says what happens when it's unset (?, :? or :-)" {
    local bare
    bare=$(grep -Hno '\${[A-Za-z_][A-Za-z0-9_]*}' "$REPO_ROOT"/docker/services/*.yaml "$REPO_ROOT"/docker/modes/*.yaml || true)
    [ -z "$bare" ] || fail "bare \${VAR} (Compose blanks it with only a warning): $bare"
}

@test "build overlay is valid" {
    DISTRO_SOURCE_DIR=/tmp/distro compose_config build.yaml
    assert_valid
}

@test "a variable in more than one .env.defaults has the same default in each" {
    local differ
    # name<TAB>line for each variable, then names with more than one distinct line.
    differ=$(grep -h '^[A-Za-z_][A-Za-z0-9_]*=' "$REPO_ROOT"/docker/services/*.env.defaults |
        awk -F= '{ print $1 "\t" $0 }' | sort -u | cut -f1 | uniq -d)
    [ -z "$differ" ] || fail "defined differently in two .env.defaults: $differ"
}

@test "sqlserver listens on 1433 inside the network, whatever host port it publishes" {
    run env SQLSERVER_PUBLISHED_PORT=1434 docker compose --env-file "$OPENMRS_DOCKER_HOME/$CONFIG_INSTANCE/env" \
        -f "$OPENMRS_DOCKER_HOME/$CONFIG_INSTANCE/sqlserver.yaml" config --format json
    assert_success
    run jq -r '.services.sqlserver.ports[] | "\(.published):\(.target)"' <<< "$output"
    assert_output '1434:1433'
}

@test "openhim has JWT authentication off, and openhim-setup passes no credentials on curl's command line" {
    local dir="$OPENMRS_DOCKER_HOME/$CONFIG_INSTANCE" args=() f
    for f in "$dir"/*.yaml; do args+=(-f "$f"); done
    run docker compose --env-file "$dir/env" "${args[@]}" config openhim-core openhim-setup
    assert_success
    # Unset, not "false": core reads env vars as strings, and the string "false" is truthy.
    refute_output --partial 'authentication_enableJWTAuthentication'
    refute_output --partial 'authentication_jwt_secretOrPublicKey'
    refute_output --regexp 'curl [^\n]*-u'
}

@test "openhim services talk plain HTTP inside the Docker network, and publish only the ports that are used from outside" {
    local dir="$OPENMRS_DOCKER_HOME/$CONFIG_INSTANCE" args=() f config
    for f in "$dir"/*.yaml; do args+=(-f "$f"); done
    run docker compose --env-file "$dir/env" "${args[@]}" config --format json
    assert_success
    config=$output
    # no HTTPS to openhim-core, and nothing that skips certificate checks
    run jq -r '.services | to_entries[] | select(.key | startswith("openhim") or startswith("mongo")) | .value' <<< "$config"
    refute_output --partial 'https://openhim-core'
    refute_output --partial 'no-check-certificate'
    refute_output --partial 'TRUST_SELF_SIGNED'
    refute_output --regexp 'curl -[a-z]*k'
    run jq -r '.services["openhim-core"].environment.api_protocol' <<< "$config"
    assert_output http
    # so the console's Secure session cookie can be set behind the TLS-terminating proxy
    run jq -r '.services["openhim-core"].environment.api_trustProxy' <<< "$config"
    assert_output true
    # OpenHIM's own images on release tags, not latest
    run jq -r '.services["openhim-core"].image, .services["openhim-console"].image' <<< "$config"
    refute_output --partial ':latest'
    run jq -r '.services["openhim-core"].environment | .mongo_url, .mongo_atnaUrl' <<< "$config"
    assert_output $'mongodb://mongo-db/openhim\nmongodb://mongo-db/openhim'
    # the admin API (for the console, which runs in the admin's browser) and the router's HTTP port
    run jq -c '[.services["openhim-core"].ports[].target] | sort' <<< "$config"
    assert_output '[5001,8080]'
    run jq -c '[.services["openhim-console"].ports[].target]' <<< "$config"
    assert_output '[80]'
    run jq -r '[.services["mongo-db"].ports // [], .services["openhim-advapacs-mediator"].ports // []] | flatten | length' <<< "$config"
    assert_output 0
}

@test "petl gets only its config namespaces from env, and keeps its job history in a volume" {
    local dir="$OPENMRS_DOCKER_HOME/$CONFIG_INSTANCE" args=() f json
    printf "DATASOURCES_OPENMRS_CESCI_HOST='openmrs-db'\nOTHER_SECRET='nope'\n" >> "$dir/env"
    "$BIN/openmrs-docker" "$CONFIG_INSTANCE" status >/dev/null 2>&1 || true   # every command regenerates petl.env
    run grep -E '^(DATASOURCES_OPENMRS_CESCI_HOST|OTHER_SECRET)=' "$dir/petl.env"
    assert_output "DATASOURCES_OPENMRS_CESCI_HOST='openmrs-db'"
    for f in "$dir"/*.yaml; do args+=(-f "$f"); done
    run docker compose --env-file "$dir/env" "${args[@]}" --profile petl config --format json
    assert_success
    json=$output
    run jq -r '.services.petl.volumes[] | "\(.source):\(.target)"' <<< "$json"
    assert_output "petl-data:/home/petl/data"
}

@test "advapacs-gateway uses the host's network, publishes nothing, and keeps its data directory in a volume" {
    local dir="$OPENMRS_DOCKER_HOME/$CONFIG_INSTANCE" args=() f config
    for f in "$dir"/*.yaml; do args+=(-f "$f"); done
    run docker compose --env-file "$dir/env" "${args[@]}" config --format json
    assert_success
    config=$output
    # its DICOM and HL7 ports are whatever AdvaPACS is configured with
    run jq -r '.services["advapacs-gateway"] | .network_mode, (.ports // [] | length)' <<< "$config"
    assert_output $'host\n0'
    # a release tag, as AdvaPACS recommends, not latest
    run jq -r '.services["advapacs-gateway"].image' <<< "$config"
    assert_output --regexp '^advahealthsolutions/advapacs-gateway:[0-9]'
    # the instance's prefixed ADVAPACS_GATEWAY_* settings, under the names the gateway reads
    run jq -r '.services["advapacs-gateway"].environment
        | .ADVAPACS_REGION, .ADVAPACS_ACCESS_KEY_ID, .ADVAPACS_ACCESS_KEY_SECRET' <<< "$config"
    assert_output $'placeholder-region\nplaceholder-id\nplaceholder-secret'
    # the image's default data directory, which the gateway's Data Directory in AdvaPACS must stay at
    run jq -r '.services["advapacs-gateway"].volumes[] | select(.type == "volume") | .target' <<< "$config"
    assert_output /opt/AdvaHealthSolutions/AdvaPACSGateway
}

@test "modality-simulator reaches the gateway through the host, keeps its log in a volume, and mounts its image library read-only" {
    local dir="$OPENMRS_DOCKER_HOME/$CONFIG_INSTANCE" args=() f config
    for f in "$dir"/*.yaml; do args+=(-f "$f"); done
    run docker compose --env-file "$dir/env" "${args[@]}" config --format json
    assert_success
    config=$output
    # the gateway uses the host's network, so it's reached through the host; no hard dependency,
    # since the gateway may be outside the instance and opens its port only once configured
    run jq -c '.services["modality-simulator"].extra_hosts' <<< "$config"
    assert_output --partial 'host.docker.internal'
    assert_output --partial 'host-gateway'
    run jq -r '.services["modality-simulator"].depends_on // {} | has("advapacs-gateway")' <<< "$config"
    assert_output false
    run jq -r '.services["modality-simulator"].ports[] | "\(.published):\(.target)"' <<< "$config"
    assert_output '8095:8080'
    # the instance's MODALITY_SIMULATOR_* settings, under the same names; Compose-only ones not passed
    run jq -r '.services["modality-simulator"].environment
        | .MODALITY_SIMULATOR_GATEWAY_AE, .MODALITY_SIMULATOR_GATEWAY_HOST, .MODALITY_SIMULATOR_GATEWAY_PORT,
          has("MODALITY_SIMULATOR_IMAGE_DIR")' <<< "$config"
    assert_output $'PLACEHOLDER_GW\nhost.docker.internal\n11112\nfalse'
    run jq -r '.services["modality-simulator"].volumes[] | "\(.type) \(.target) \(.read_only // false)"' <<< "$config"
    assert_output $'volume /data false\nbind /images true'
    # the image library defaults to a directory in the instance
    run jq -r '.services["modality-simulator"].volumes[] | select(.target == "/images") | .source' <<< "$config"
    assert_output "$dir/modality-simulator-images"
}
