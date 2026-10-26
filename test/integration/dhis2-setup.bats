#!/usr/bin/env bats
# The dhis2 service: dhis2-setup checks the release WAR is there and writes dhis.conf into the DHIS2
# home volume from env, before every start. Against a stub Tomcat image (build_stub_dhis2_image).

load ../helpers

setup_file() { build_stub_dhis2_image; }

setup() {
    NAME="$(instance)"
    DIR="$OPENMRS_DOCKER_HOME/$NAME"
}
teardown() {
    destroy_instance "$NAME"
    common_teardown
}

create_dhis2() { # creates the instance and puts a (dummy) WAR in place
    SERVICES=dhis2-db,dhis2 DHIS2_IMAGE_NAME="$STUB_DHIS2_IMAGE" DHIS2_IMAGE_TAG=latest DHIS2_VERSION=2.41.8.1 \
        create_instance "$NAME"
    mkdir -p "$DIR/wars" && echo war > "$DIR/wars/dhis2-2.41.8.1.war"
}
dhis_conf() { docker run --rm -v "${NAME}_dhis2-data:/home" "$ALPINE_IMAGE" cat /home/dhis.conf; }

@test "dhis2-setup writes dhis.conf from env" {
    create_dhis2
    run "$BIN/openmrs-docker" "$NAME" start
    assert_success
    run dhis_conf
    assert_output --partial 'connection.url = jdbc:postgresql://dhis2-db/dhis'
    assert_output --partial 'connection.username = dhis'
    assert_output --partial 'connection.schema = update'
    assert_output --regexp 'server.base.url = http://localhost:[0-9]+/dhis'
    refute_output --partial 'encryption.password'
    run docker run --rm -v "${NAME}_dhis2-data:/home" "$ALPINE_IMAGE" stat -c '%a' /home/dhis.conf
    assert_output 600
}

@test "dhis.conf holds special-character secrets as DHIS2 reads them" {
    local secret='p$HOME"x`id`\z#1'
    DHIS2_DB_PASSWORD="$secret" DHIS2_ENCRYPTION_PASSWORD="$secret" create_dhis2
    record_docker_argv
    run "$BIN/openmrs-docker" "$NAME" start
    assert_success
    assert_not_in_docker_argv "$secret"
    # dhis.conf is a Java properties file: a backslash is written as \\ so DHIS2 reads one.
    run dhis_conf
    assert_output --partial 'connection.password = p$HOME"x`id`\\z#1'
    assert_output --partial 'encryption.password = p$HOME"x`id`\\z#1'
}

@test "DHIS2_CONF_* become dhis.conf keys" {
    DHIS2_CONF_connection_pool_max__size=40 create_dhis2
    "$BIN/openmrs-docker" "$NAME" start >/dev/null 2>&1
    run dhis_conf
    assert_output --partial 'connection.pool.max_size = 40'
}

@test "DHIS2_CONF_connection_schema comes after the default, so it's the one DHIS2 reads" {
    DHIS2_CONF_connection_schema=validate create_dhis2
    "$BIN/openmrs-docker" "$NAME" start >/dev/null 2>&1
    run sh -c "$(declare -f dhis_conf); NAME=$NAME ALPINE_IMAGE=$ALPINE_IMAGE dhis_conf | grep '^connection.schema' | tail -1"
    assert_output 'connection.schema = validate'
}

@test "dhis2 becomes healthy behind dhis2-setup" {
    create_dhis2
    "$BIN/openmrs-docker" "$NAME" start >/dev/null 2>&1
    run "$UTILS/wait-for-healthy.sh" --container="$NAME-dhis2" --timeout=120
    assert_success
}

@test "rewrites dhis.conf on each start" {
    create_dhis2
    "$BIN/openmrs-docker" "$NAME" start >/dev/null 2>&1
    sed -i "s/^DHIS2_DB_PASSWORD=.*/DHIS2_DB_PASSWORD='changed'/" "$DIR/env"
    run "$BIN/openmrs-docker" "$NAME" start
    assert_success
    run dhis_conf
    assert_output --partial 'connection.password = changed'
}

@test "start fails naming the WAR when it is missing, and dhis2 is never created" {
    create_dhis2
    rm -f "$DIR/wars/dhis2-2.41.8.1.war"
    run "$BIN/openmrs-docker" "$NAME" start
    assert_failure
    assert_output --partial 'wars/dhis2-2.41.8.1.war'
    run docker inspect "$NAME-dhis2"
    assert_failure
}
