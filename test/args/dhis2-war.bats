#!/usr/bin/env bats
# dhis2-war fetches a DHIS2 release WAR into an instance's wars/ directory (or any directory),
# verified against the SHA-256 pinned in docker/dhis2/upgrade-path, and never leaves a bad file.

load ../helpers

setup() {
    cd "$BATS_TEST_TMPDIR"
    printf 'not really a war\n' > release.war
    SHA=$(sha256sum release.war | cut -d' ' -f1)
    printf '# test path\n2.31.9 9-jdk8 file://%s/release.war %s\n2.32.7 9-jdk8 file://%s/missing.war %s\n' \
        "$PWD" "$SHA" "$PWD" "$SHA" > path
    export DHIS2_UPGRADE_PATH="$PWD/path"
}
teardown() { common_teardown; }

@test "downloads and verifies a WAR into --output-dir" {
    run "$UTILS/dhis2-war.sh" --version=2.31.9 --output-dir=out
    assert_success
    run cmp release.war out/dhis2-2.31.9.war
    assert_success
}

@test "--instance means the instance's wars directory" {
    mkdir -p "$OPENMRS_DOCKER_HOME/$(instance)"
    run "$UTILS/dhis2-war.sh" --version=2.31.9 --instance="$(instance)"
    assert_success
    assert [ -s "$OPENMRS_DOCKER_HOME/$(instance)/wars/dhis2-2.31.9.war" ]
    rm -rf "${OPENMRS_DOCKER_HOME:?}/$(instance)"
}

@test "refuses a checksum mismatch and leaves no file" {
    sed -i "s/$SHA/$(printf '0%.0s' {1..64})/" path
    run "$UTILS/dhis2-war.sh" --version=2.31.9 --output-dir=out
    assert_failure
    assert_output --partial 'SHA-256'
    run ls -A out
    assert_output ''
}

@test "refuses a version not in the upgrade path unless given --url and --sha256" {
    run "$UTILS/dhis2-war.sh" --version=2.99.1 --output-dir=out
    assert_failure
    assert_output --partial '2.99.1'
    run "$UTILS/dhis2-war.sh" --version=2.99.1 --url="file://$PWD/release.war" --sha256="$SHA" --output-dir=out
    assert_success
    assert [ -s out/dhis2-2.99.1.war ]
}

@test "keeps an existing verified WAR without downloading" {
    mkdir out && cp release.war out/dhis2-2.32.7.war
    run "$UTILS/dhis2-war.sh" --version=2.32.7 --output-dir=out
    assert_success
    assert_output --partial 'already'
}

@test "replaces an existing WAR that doesn't verify" {
    mkdir out && echo corrupt > out/dhis2-2.31.9.war
    run "$UTILS/dhis2-war.sh" --version=2.31.9 --output-dir=out
    assert_success
    run cmp release.war out/dhis2-2.31.9.war
    assert_success
}
