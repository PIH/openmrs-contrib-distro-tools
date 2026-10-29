#!/usr/bin/env bats
# Every service directory under services/ is valid Compose against its own defaults (and those of
# the services it requires), and the services render as they should together. Compose is run as pihx
# runs it: the instance's env files in override order, an environment of only what pihx sets, and
# the instance directory as the project directory.
#
# The tree's structure (the three files, the manifest, the env file convention, no relative paths)
# is checked by pihx/tests/test_service_tree.py, which needs PyYAML and so runs in pihx-runtime
# (test/run unit).

load ../helpers

setup_file() {
    export ALL_SERVICES
    ALL_SERVICES=$(cd "$REPO_ROOT/services" && ls -d */ | tr -d / | paste -sd' ' -)
}

# The placeholder values for what no service gives a default.
make_instance() { # <dir>
    local dir=$1
    mkdir -p "$dir"
    cat > "$dir/openmrs.env" <<'ENV'
OPENMRS_IMAGE_NAME=placeholder/openmrs
ENV
    echo "PETL_MYSQL_PASSWORD=Placeholder-1" > "$dir/petl.env"
    echo "SQLSERVER_SA_PASSWORD=Placeholder-1" > "$dir/sqlserver.env"
    echo "MODALITY_SIMULATOR_GATEWAY_AE=PLACEHOLDER_GW" > "$dir/modality-simulator.env"
    echo "BIOMETRICS_LICENSE_BASE64=cGxhY2Vob2xkZXI=" > "$dir/biometrics.env"
    printf '%s\n' ADVAPACS_GATEWAY_REGION=placeholder-region ADVAPACS_GATEWAY_ACCESS_KEY_ID=placeholder-id \
        ADVAPACS_GATEWAY_ACCESS_KEY_SECRET=placeholder-secret > "$dir/advapacs-gateway.env"
}

# <service> and, recursively, the services its manifest requires.
closure() {
    local svc=$1 required
    echo "$svc"
    for required in $(sed -n 's/^requires: *\[\(.*\)\]/\1/p' "$REPO_ROOT/services/$svc/service.yaml" | tr ',' ' '); do
        closure "$required"
    done
}

# All the services together; the arguments follow `config`.
make_and_run() {
    local dir="$BATS_TEST_TMPDIR/instance"
    make_instance "$dir"
    instance_compose "$dir" "${ALL_SERVICES// /,}" -- config "$@"
}

# A failure mentioning an unset variable always means an inline script's `$VAR` that should have
# been escaped as `$$VAR`.
assert_valid() {
    assert_success
    refute_output --partial 'variable is not set'
}

@test "every service has a manifest, a compose file and env defaults, and no other service is missing from the tree" {
    local svc
    [ -n "$ALL_SERVICES" ]
    for svc in $ALL_SERVICES; do
        [ -f "$REPO_ROOT/services/$svc/service.yaml" ] || fail "$svc: no service.yaml"
        [ -f "$REPO_ROOT/services/$svc/compose.yaml" ] || fail "$svc: no compose.yaml"
        [ -f "$REPO_ROOT/services/$svc/env.defaults" ] || fail "$svc: no env.defaults"
    done
}

@test "every service is valid Compose with its own defaults and those of the services it requires" {
    local svc dir="$BATS_TEST_TMPDIR/instance" failures=""
    EXTRA_ENV=()
    make_instance "$dir"
    for svc in $ALL_SERVICES; do
        run instance_compose "$dir" "$(closure "$svc" | sort -u | paste -sd, -)" -- config -q
        if [ "$status" -ne 0 ] || [[ "$output" == *'variable is not set'* ]]; then
            failures+="$svc: $output"$'\n'
        fi
    done
    [ -z "$failures" ] || fail "$failures"
}

@test "every service together is valid" {
    EXTRA_ENV=()
    run make_and_run -q
    assert_valid
}

@test "a required value with no default is refused with its message when the instance doesn't set it" {
    local dir="$BATS_TEST_TMPDIR/instance" svc var
    EXTRA_ENV=()
    make_instance "$dir"
    for pair in openmrs:OPENMRS_IMAGE_NAME petl:PETL_MYSQL_PASSWORD sqlserver:SQLSERVER_SA_PASSWORD \
            modality-simulator:MODALITY_SIMULATOR_GATEWAY_AE biometrics:BIOMETRICS_LICENSE_BASE64 \
            advapacs-gateway:ADVAPACS_GATEWAY_REGION; do
        svc=${pair%%:*} var=${pair#*:}
        cp "$dir/$svc.env" "$dir/$svc.env.saved"
        grep -v "^$var=" "$dir/$svc.env.saved" > "$dir/$svc.env" || true
        run instance_compose "$dir" "$(closure "$svc" | sort -u | paste -sd, -)" -- config -q
        assert_failure
        assert_output --partial "$var"
        mv "$dir/$svc.env.saved" "$dir/$svc.env"
    done
}

@test "env values with special characters survive Compose's reading, from defaults and from the instance's file" {
    local dir="$BATS_TEST_TMPDIR/instance"
    EXTRA_ENV=()
    make_instance "$dir"
    # a default with `&`, `%` and a `${...}` that isn't Compose's to expand (petl's)
    run instance_compose "$dir" openmrs-db,petl -- --profile petl config --format json
    assert_success
    run jq -r '.services.petl.environment.PETL_MYSQL_OPTIONS' <<< "$output"
    assert_output --partial 'default_storage_engine%3DInnoDB&useUnicode=true'
    assert_output --partial 'serverTimezone=$${user.timezone}'   # `config` shows a literal $ as $$
    # single-quoted values in the instance's file stay literal
    cat > "$dir/openmrs-db.env" <<'ENV'
OPENMRS_DB_PASSWORD='p$w #rd "q" `x` \y'
ENV
    run instance_compose "$dir" openmrs-db -- config --format json
    assert_success
    run jq -r '.services["openmrs-db"].environment.MYSQL_PASSWORD' <<< "$output"
    assert_output 'p$$w #rd "q" `x` \y'   # `config` writes a literal $ as $$
}

@test "an instance's <svc>.override.yaml applies after the service's compose file" {
    local dir="$BATS_TEST_TMPDIR/instance"
    EXTRA_ENV=()
    make_instance "$dir"
    printf 'services:\n  openmrs-db:\n    ports: !override\n      - "13306:3306"\n' > "$dir/openmrs-db.override.yaml"
    run instance_compose "$dir" openmrs-db -- config --format json
    assert_success
    run jq -r '.services["openmrs-db"].ports[] | "\(.published):\(.target)"' <<< "$output"
    assert_output '13306:3306'
}

# The OpenMRS front end's dev and build overlays (openmrs/modes/), and the services' restore overlays
# (services/<svc>/restore/), checked with the values the front end and initialize set.
overlay_config() { # <overlay...>, under openmrs/modes/ or services/
    EXTRA_ENV=(OPENMRS_DB_RESTORE_PATH=/tmp/openmrs-db.sql OPENMRS_DB_RESTORE_NAME=openmrs-db.sql
        OPENMRS_DB_RESTORE_ARCHIVE=archive.7z OPENMRS_RESTORE_PATH=/tmp/openmrs.7z
        OPENMRS_RESTORE_NAME=openmrs.7z OPENMRS_RESTORE_ARCHIVE=archive.7z OPENMRS_DATA_OWNER=1:1
        DISTRO_SOURCE_DIR=/tmp/distro ALPINE_IMAGE=placeholder/alpine P7ZIP_IMAGE=placeholder/p7zip
        PERCONA_IMAGE=placeholder/percona)
    local dir="$BATS_TEST_TMPDIR/instance"
    make_instance "$dir"
    instance_compose "$dir" "${ALL_SERVICES// /,}" "${@/#/+}" -- config -q
}

@test "dev, build and every restore overlay is valid with the services" {
    local o failures=""
    for o in openmrs/modes/dev.yaml openmrs/modes/build.yaml services/openmrs-db/restore/dump.yaml \
            services/openmrs-db/restore/dump-archive.yaml services/openmrs/restore/archive.yaml \
            services/openmrs/restore/directory.yaml; do
        run overlay_config "$o"
        if [ "$status" -ne 0 ] || [[ "$output" == *'variable is not set'* ]]; then failures+="$o: $output"$'\n'; fi
    done
    run overlay_config services/openmrs-db/restore/datadir.yaml services/openmrs-db/restore/reset-accounts.yaml
    [ "$status" -eq 0 ] || failures+="datadir: $output"$'\n'
    run overlay_config services/openmrs-db/restore/percona.yaml services/openmrs-db/restore/reset-accounts.yaml
    [ "$status" -eq 0 ] || failures+="percona: $output"$'\n'
    run overlay_config services/openmrs-db/restore/dump-archive.yaml services/openmrs/restore/archive.yaml
    [ "$status" -eq 0 ] || failures+="both: $output"$'\n'
    [ -z "$failures" ] || fail "$failures"
}

@test "an OMRS_EXTRA_* variable in openmrs.env reaches the openmrs container's environment" {
    local dir="$BATS_TEST_TMPDIR/instance"
    EXTRA_ENV=()
    make_instance "$dir"
    echo "OMRS_EXTRA_pihmalawi_warehouse_connection_url='jdbc:mysql://openmrs-db:3306/openmrs_warehouse'" >> "$dir/openmrs.env"
    run instance_compose "$dir" openmrs-db,openmrs -- config
    assert_success
    assert_output --partial 'OMRS_EXTRA_pihmalawi_warehouse_connection_url: jdbc:mysql://openmrs-db:3306/openmrs_warehouse'
}

@test "openmrs sets pih_config under the image's own OMRS_EXTRA_ name, so it overrides the image default" {
    local dir="$BATS_TEST_TMPDIR/instance"
    EXTRA_ENV=()
    make_instance "$dir"
    echo "OPENMRS_PIH_CONFIG='haiti,haiti-test'" >> "$dir/openmrs.env"
    run instance_compose "$dir" openmrs-db,openmrs -- config
    assert_success
    assert_output --partial 'OMRS_EXTRA_pih_config: haiti,haiti-test'
    refute_output --partial 'OMRS_EXTRA_PIH_CONFIG'
}

@test "openmrs fails 'wait' as soon as it is unhealthy" {
    EXTRA_ENV=()
    run make_and_run --format json
    assert_success
    run jq -r '.services.openmrs.labels["pihx.wait"]' <<< "$output"
    assert_output fail-on-unhealthy
}

@test "openhim-core runs an init process, so zombie ssl_client processes from its healthcheck are reaped" {
    # BusyBox wget spawns an ssl_client helper per HTTPS request. When wget exits, the helper is
    # reparented to the container's PID 1 -- in openhim-core that's Node, which never reaps it.
    # Each zombie pins a seccomp filter's BPF JIT memory until the host can't load new filters.
    EXTRA_ENV=()
    run make_and_run openhim-core
    assert_success
    assert_output --partial 'init: true'
}

@test "openmrs-db gets its OPENMRS_DB_OPT_* server options from its defaults and its file" {
    local dir="$BATS_TEST_TMPDIR/instance"
    EXTRA_ENV=()
    make_instance "$dir"
    echo "OPENMRS_DB_OPT_max_allowed_packet=256M" > "$dir/openmrs-db.env"
    run instance_compose "$dir" openmrs-db -- config openmrs-db
    assert_success
    assert_output --partial 'OPENMRS_DB_OPT_character_set_server: utf8'
    assert_output --partial 'OPENMRS_DB_OPT_max_allowed_packet: 256M'
    refute_output --partial 'log_bin:'
}

@test "the accounts and logins PETL declares reach openmrs-db's and sqlserver's setup only when the instance has both, and openmrs-db and sqlserver don't mention PETL" {
    local dir="$BATS_TEST_TMPDIR/instance"
    EXTRA_ENV=()
    make_instance "$dir"
    echo "PETL_MYSQL_REPORTING_DATABASE=reporting" >> "$dir/petl.env"
    run instance_compose "$dir" openmrs-db,sqlserver,petl -- config --format json
    assert_success
    local config=$output
    run jq -r '.services["openmrs-db-accounts"].environment | .OPENMRS_DB_ACCOUNT_PETL_USER, .OPENMRS_DB_ACCOUNT_PETL_PASSWORD,
        .OPENMRS_DB_ACCOUNT_PETL_GRANTS, .OPENMRS_DB_ACCOUNT_PETL_DATABASES' <<< "$config"
    assert_output $'petl\nPlaceholder-1\nALL ON *.*\nreporting'
    run jq -r '.services["sqlserver-setup"].environment | .SQLSERVER_LOGIN_PETL_USER, .SQLSERVER_LOGIN_PETL_DATABASES' <<< "$config"
    assert_output $'petl\nopenmrs_reporting'
    run instance_compose "$dir" openmrs-db,sqlserver -- config --format json
    assert_success
    run jq -r '[.services["openmrs-db-accounts"].environment, .services["sqlserver-setup"].environment]
        | map(to_entries[] | select(.key | test("_PETL_")) | .value) | join("")' <<< "$output"
    assert_output ''
    # (without petl, nothing mentions it)
    rm "$dir/petl.env"
    run instance_compose "$dir" openmrs-db,sqlserver -- config --format json
    assert_success
    refute_output --partial PETL
}

@test "sqlserver listens on 1433 inside the network, whatever host port it publishes" {
    local dir="$BATS_TEST_TMPDIR/instance"
    EXTRA_ENV=()
    make_instance "$dir"
    echo "SQLSERVER_PUBLISHED_PORT=1434" >> "$dir/sqlserver.env"
    run instance_compose "$dir" sqlserver -- config --format json
    assert_success
    run jq -r '.services.sqlserver.ports[] | "\(.published):\(.target)"' <<< "$output"
    assert_output '1434:1433'
}

@test "openhim has JWT authentication off, and openhim-setup passes no credentials on curl's command line" {
    EXTRA_ENV=()
    run make_and_run openhim-core openhim-setup
    assert_success
    # Unset, not "false": core reads env vars as strings, and the string "false" is truthy.
    refute_output --partial 'authentication_enableJWTAuthentication'
    refute_output --partial 'authentication_jwt_secretOrPublicKey'
    refute_output --regexp 'curl [^\n]*-u'
}

@test "openhim services talk plain HTTP inside the Docker network, and publish only the ports that are used from outside" {
    local config
    EXTRA_ENV=()
    run make_and_run --format json
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

@test "the openhim console's addresses follow its host ports unless set" {
    local dir="$BATS_TEST_TMPDIR/instance"
    EXTRA_ENV=()
    make_instance "$dir"
    printf 'OPENHIM_CONSOLE_HOST_PORT=9100\nOPENHIM_ADMIN_API_HOST_PORT=8181\n' > "$dir/openhim.env"
    run instance_compose "$dir" openhim -- config --format json
    assert_success
    run jq -r '.services["openhim-core"].environment.openhimConsoleBaseUrl, .services["openhim-console"].environment.OPENHIM_MEDIATOR_API_PORT' <<< "$output"
    assert_output $'http://localhost:9100\n8181'
}

@test "petl gets the properties in its file, and keeps its job history in a volume" {
    local dir="$BATS_TEST_TMPDIR/instance" json
    EXTRA_ENV=()
    make_instance "$dir"
    echo "DATASOURCES_OPENMRS_CESCI_HOST='openmrs-db'" >> "$dir/petl.env"
    run instance_compose "$dir" openmrs-db,petl -- --profile petl config --format json
    assert_success
    json=$output
    run jq -r '.services.petl.environment.DATASOURCES_OPENMRS_CESCI_HOST' <<< "$json"
    assert_output openmrs-db
    run jq -r '.services.petl.volumes[] | "\(.source):\(.target)"' <<< "$json"
    assert_output "petl-data:/home/petl/data"
}

@test "advapacs-gateway uses the host's network, publishes nothing, and keeps its data directory in a volume" {
    local config
    EXTRA_ENV=()
    run make_and_run --format json
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
    local config
    EXTRA_ENV=()
    run make_and_run --format json
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
    # the instance's MODALITY_SIMULATOR_* settings, under the same names
    run jq -r '.services["modality-simulator"].environment
        | .MODALITY_SIMULATOR_GATEWAY_AE, .MODALITY_SIMULATOR_GATEWAY_HOST, .MODALITY_SIMULATOR_GATEWAY_PORT' <<< "$config"
    assert_output $'PLACEHOLDER_GW\nhost.docker.internal\n11112'
    run jq -r '.services["modality-simulator"].volumes[] | "\(.type) \(.target) \(.read_only // false)"' <<< "$config"
    assert_output $'volume /data false\nbind /images true'
    # the image library defaults to a directory in the instance
    run jq -r '.services["modality-simulator"].volumes[] | select(.target == "/images") | .source' <<< "$config"
    assert_output "$BATS_TEST_TMPDIR/instance/modality-simulator-images"
}

@test "biometrics publishes nothing, keeps a stable hostname and its data and license identity in volumes, and passes its settings under the image's names" {
    local config
    EXTRA_ENV=()
    run make_and_run --format json
    assert_success
    config=$output
    # OpenMRS reaches it on the instance's network as http://biometrics:9000
    run jq -r '.services.biometrics.ports // [] | length' <<< "$config"
    assert_output 0
    # the Neurotechnology license follows the hostname and the identity it keeps in /var/tmp, so both
    # must survive the container being recreated
    run jq -r '.services.biometrics.hostname' <<< "$config"
    assert_output "config-biometrics"
    # the instance's BIOMETRICS_* settings, under the image's PIH_BIOMETRICS_* names, with the app's own defaults
    run jq -r '.services.biometrics.environment
        | .PIH_BIOMETRICS_LICENSE_BASE64, .PIH_BIOMETRICS_MATCHING_THRESHOLD, .PIH_BIOMETRICS_MATCHING_SPEED,
          .PIH_BIOMETRICS_TEMPLATE_SIZE' <<< "$config"
    assert_output $'cGxhY2Vob2xkZXI=\n72\nLOW\nLARGE'
    run jq -r '.services.biometrics.image' <<< "$config"
    assert_output 'ghcr.io/pih/pih-biometrics:latest'
    run jq -r '.services.biometrics.volumes[] | "\(.type) \(.source) \(.target)"' <<< "$config"
    assert_output $'volume biometrics-data /opt/pih-biometrics/data\nvolume biometrics-licensing /var/tmp'
}
