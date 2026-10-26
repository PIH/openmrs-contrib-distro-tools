#!/usr/bin/env bats
# dhis2-upgrade's checks before it touches anything, and the upgrade path's format.

load ../helpers

setup() { cd "$BATS_TEST_TMPDIR"; NAME="$(instance)"; }
teardown() {
    rm -rf "${OPENMRS_DOCKER_HOME:?}/${NAME:?}"
    common_teardown
}

create_dhis2() { # <version>
    SERVICES=dhis2-db,dhis2 DHIS2_VERSION="$1" DHIS2_IMAGE_TAG=9-jdk8 create_instance "$NAME"
}

@test "refuses a version not in the path" {
    create_dhis2 2.30.0
    run "$UTILS/dhis2-upgrade.sh" --instance="$NAME" </dev/null
    assert_failure
    assert_output --partial "2.30.0 isn't in"
}

@test "refuses a non-dhis2 instance" {
    SERVICES=openmrs-db create_instance "$NAME"
    run "$UTILS/dhis2-upgrade.sh" --instance="$NAME" </dev/null
    assert_failure
    assert_output --partial 'not a DHIS2 instance'
}

@test "--to before the current version does nothing and says so" {
    create_dhis2 2.33.9
    run "$UTILS/dhis2-upgrade.sh" --instance="$NAME" --to=2.32.7 </dev/null
    assert_success
    assert_output --partial 'nothing to do'
}

@test "refuses a --to version not in the path" {
    create_dhis2 2.33.9
    run "$UTILS/dhis2-upgrade.sh" --instance="$NAME" --to=2.99 </dev/null
    assert_failure
    assert_output --partial "2.99 isn't in"
}

@test "every line of upgrade-path is a unique version with a Tomcat tag, an https WAR URL and a SHA-256" {
    local path="$REPO_ROOT/docker/dhis2/upgrade-path"
    run awk '!/^#/ && NF && !(NF == 4 && $2 ~ /^9-jdk(8|11|17)$/ && $3 ~ /^https:\/\/releases\.dhis2\.org\/.*\.war$/ && $4 ~ /^[0-9a-f]{64}$/)' "$path"
    assert_output ''
    run bash -c "grep -v '^#' '$path' | awk 'NF { print \$1 }' | sort | uniq -d"
    assert_output ''
}
