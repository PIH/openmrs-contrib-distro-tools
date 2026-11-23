#!/usr/bin/env bats
# services/dhis2/scripts/setup.sh, run with the host's sh: it checks DHIS2_VERSION and
# DHIS2_TOMCAT_TAG against a versions list, refuses a downgrade, fetches and verifies the WAR (a stub
# curl copies a fixture), and writes dhis.conf and the version marker.

load ../helpers

SCRIPT="$REPO_ROOT/services/dhis2/scripts/setup.sh"
SECRET='p$HOME"x`id`\z#1'

setup() {
    cd "$BATS_TEST_TMPDIR"
    mkdir bin home wars
    echo "a DHIS2 WAR" > fixture.war
    sum=$(sha256sum fixture.war | cut -d' ' -f1)
    cat > versions <<VERSIONS
# A test list: <version> <tomcat tag> <war url> <sha256>
2.40.1 9-jdk11-temurin-noble https://example.invalid/dhis2-2.40.1.war $sum
2.41.1 9-jdk17-temurin-noble https://example.invalid/dhis2-2.41.1.war $sum
2.42.1 9-jdk17-temurin-noble https://example.invalid/dhis2-2.42.1.war 0000000000000000000000000000000000000000000000000000000000000000
VERSIONS
    # curl -fsSL [--retry n] -o <file> <url>: copies the fixture, and records the URL.
    cat > bin/curl <<'STUB'
#!/bin/sh
out= url=
while [ $# -gt 0 ]; do
    case $1 in
        -o) out=$2; shift ;;
        --retry) shift ;;
        -*) ;;
        *) url=$1 ;;
    esac
    shift
done
echo "$url" >> "$BATS_TEST_TMPDIR/curl-calls"
cp "$BATS_TEST_TMPDIR/fixture.war" "$out"
STUB
    chmod +x bin/curl
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    export DHIS2_VERSIONS_FILE="$BATS_TEST_TMPDIR/versions" DHIS2_HOME="$BATS_TEST_TMPDIR/home" \
        DHIS2_WARS="$BATS_TEST_TMPDIR/wars" DHIS2_VERSION=2.41.1 DHIS2_TOMCAT_TAG=9-jdk17-temurin-noble \
        DHIS2_DB_NAME=dhis DHIS2_DB_USER=dhis DHIS2_DB_PASSWORD="$SECRET" \
        DHIS2_BASE_URL=http://localhost:8080/dhis
    unset DHIS2_ENCRYPTION_PASSWORD
}

@test "setup downloads and verifies the WAR, writes dhis.conf and the version marker" {
    run sh "$SCRIPT"
    assert_success
    run cat curl-calls
    assert_output https://example.invalid/dhis2-2.41.1.war
    cmp fixture.war wars/dhis2-2.41.1.war
    [ ! -e wars/dhis2-2.41.1.war.part ]
    run cat home/dhis.conf
    assert_line 'connection.url = jdbc:postgresql://dhis2-db/dhis'
    assert_line 'connection.username = dhis'
    assert_line 'connection.schema = update'
    assert_line 'server.base.url = http://localhost:8080/dhis'
    refute_output --partial encryption.password
    run stat -c '%a' home/dhis.conf
    assert_output 600
    run cat home/.dhis2-version
    assert_output 2.41.1
}

@test "setup keeps a WAR already there that matches, without downloading" {
    cp fixture.war wars/dhis2-2.41.1.war
    run sh "$SCRIPT"
    assert_success
    [ ! -e curl-calls ]
    cmp fixture.war wars/dhis2-2.41.1.war
}

@test "setup deletes a WAR whose checksum doesn't match" {
    echo "something else" > wars/dhis2-2.42.1.war
    DHIS2_VERSION=2.42.1 run sh "$SCRIPT"
    assert_failure
    assert_output --partial https://example.invalid/dhis2-2.42.1.war
    [ ! -e wars/dhis2-2.42.1.war ]
    [ ! -e wars/dhis2-2.42.1.war.part ]
    [ ! -e home/.dhis2-version ]
}

@test "setup refuses a version older than the one last started" {
    echo 2.41.1 > home/.dhis2-version
    DHIS2_VERSION=2.40.1 DHIS2_TOMCAT_TAG=9-jdk11-temurin-noble run sh "$SCRIPT"
    assert_failure
    assert_output "error: this instance last ran DHIS2 2.41.1; DHIS2_VERSION is 2.40.1. DHIS2 can't be downgraded: set DHIS2_VERSION to 2.41.1 or later."
    [ ! -e curl-calls ]
    run cat home/.dhis2-version
    assert_output 2.41.1
    # The same version, or a later one, starts.
    run sh "$SCRIPT"
    assert_success
}

@test "setup refuses a last-started version it can't place in the list" {
    echo 2.99.9 > home/.dhis2-version
    run sh "$SCRIPT"
    assert_failure
    assert_output --partial "2.99.9"
    [ ! -e curl-calls ]
}

@test "setup refuses a version not in the list" {
    DHIS2_VERSION=2.39.0 run sh "$SCRIPT"
    assert_failure
    assert_output "error: DHIS2_VERSION '2.39.0' isn't in services/dhis2/scripts/versions"
    [ ! -e curl-calls ]
}

@test "setup refuses a Tomcat tag that doesn't match the version" {
    DHIS2_VERSION=2.40.1 run sh "$SCRIPT"
    assert_failure
    assert_output "error: DHIS2 2.40.1 runs on tomcat:9-jdk11-temurin-noble; DHIS2_TOMCAT_TAG is 9-jdk17-temurin-noble. Set DHIS2_TOMCAT_TAG=9-jdk11-temurin-noble."
    [ ! -e curl-calls ]
}

@test "dhis.conf escapes backslashes and maps DHIS2_CONF_ names" {
    DHIS2_ENCRYPTION_PASSWORD="$SECRET" DHIS2_CONF_connection_pool_max__size=40 \
        DHIS2_CONF_connection_schema=validate run sh "$SCRIPT"
    assert_success
    run cat home/dhis.conf
    # A Java properties file: a backslash is written as \\ so DHIS2 reads one.
    assert_line 'connection.password = p$HOME"x`id`\\z#1'
    assert_line 'encryption.password = p$HOME"x`id`\\z#1'
    assert_line 'connection.pool.max_size = 40'
    # After the default, so it's the one DHIS2 reads.
    run sh -c "grep '^connection.schema' home/dhis.conf | tail -1"
    assert_output 'connection.schema = validate'
}

@test "setup never prints the database password" {
    DHIS2_ENCRYPTION_PASSWORD="$SECRET" run sh "$SCRIPT"
    assert_success
    refute_output --partial 'p$HOME'
    echo "x" > wars/dhis2-2.42.1.war
    DHIS2_VERSION=2.42.1 run sh "$SCRIPT"
    refute_output --partial 'p$HOME'
}
