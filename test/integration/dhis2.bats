#!/usr/bin/env bats
# dhis2: a real DHIS2 release in the stock Tomcat, on an empty dhis2-db (never real data). The first
# test downloads the 2.43.2.1 WAR (about 345 MB) and waits for DHIS2 to build its schema.

load ../helpers

setup() {
    cd "$BATS_TEST_TMPDIR"
    NAME="$(instance)"
    export DHIS2_DB_PASSWORD='Placeholder-1' DHIS2_DB_PORT=0 DHIS2_HTTP_PORT=0
}
teardown() {
    remove_test_instance "$NAME"
    common_teardown
}

in_home() { # <command...>, in the DHIS2 home volume
    docker run --rm -v "${NAME}_dhis2-data:/home" "$ALPINE_IMAGE" "$@"
}

@test "DHIS2 2.43.2.1 comes up at /dhis on an empty database" {
    DHIS2_VERSION=2.43.2.1 "$BIN/pihx" "$NAME" create --services=dhis2-db,dhis2 >/dev/null
    run "$BIN/pihx" "$NAME" start
    assert_success
    # The healthcheck's /dhis/ answers on 2.43 (healthcheck.sh).
    run "$UTILS/wait-for-healthy.sh" --container="$NAME-dhis2" --timeout=1800
    assert_success
    local port
    port=$(docker port "$NAME-dhis2" 8080/tcp | head -n 1 | sed 's/.*://')
    run curl -s -o /dev/null -w '%{http_code}' "http://localhost:$port/dhis/"
    assert_output --regexp '^(200|302)$'
    run in_home cat /home/.dhis2-version
    assert_output 2.43.2.1
    run in_home stat -c '%a' /home/dhis.conf
    assert_output 600
    # Logs go only to docker logs: none in the home volume, nor Tomcat's in the container.
    run in_home ls -A /home
    refute_line logs
    run docker exec "$NAME-dhis2" ls -A /usr/local/tomcat/logs
    assert_output ""
    run docker logs "$NAME-dhis2"
    assert_output --partial 'Aborting default log config, external config set through system prop log4j2.configurationFile'
    assert_output --partial 'Server startup in'
}

@test "a start with an older DHIS2_VERSION fails in setup" {
    DHIS2_VERSION=2.43.2.1 "$BIN/pihx" "$NAME" create --services=dhis2-db,dhis2 >/dev/null
    # As a start of 2.43.2.1 leaves it, without the download and DHIS2's first start: setup refuses
    # the older version before fetching anything.
    docker volume create --label "pihx.instance=$NAME" "${NAME}_dhis2-data" >/dev/null
    in_home sh -c 'echo 2.43.2.1 > /home/.dhis2-version'
    set_env_value "$NAME" dhis2 DHIS2_VERSION 2.42.7.1
    run "$BIN/pihx" "$NAME" start
    assert_failure
    assert_output --partial '"dhis2-setup" didn'"'"'t complete successfully'
    # (Compose's up fails on it before pihx would show its log, so the reason is in its log.)
    run docker logs "$NAME-dhis2-setup"
    assert_output "error: this instance last ran DHIS2 2.43.2.1; DHIS2_VERSION is 2.42.7.1. DHIS2 can't be downgraded: set DHIS2_VERSION to 2.43.2.1 or later."
    run docker ps -q --filter "name=^$NAME-dhis2$"
    assert_output ""
}
