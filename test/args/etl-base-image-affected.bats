#!/usr/bin/env bats
# etl-base-image-affected.sh: after petl publishes an image, an ETL project rebuilds only if its
# Dockerfile builds on one of the tags that just moved.

load ../helpers

SCRIPT="$REPO_ROOT/.github/actions/etl-base-image-affected/affected.sh"
TAGS='["latest","3.8.0-SNAPSHOT"]'

dockerfile() { # <ARG line value>
    printf '# comment\nARG PETL_BASE_IMAGE=%s\nFROM ${PETL_BASE_IMAGE}\n' "$1" > "$BATS_TEST_TMPDIR/Dockerfile"
}
affected() { # [tags]
    GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out" run "$SCRIPT" "$BATS_TEST_TMPDIR/Dockerfile" PETL_BASE_IMAGE partnersinhealth/petl "${1:-$TAGS}"
}
output_of() { grep "^affected=" "$BATS_TEST_TMPDIR/out"; }

@test "a project on latest is affected" {
    dockerfile partnersinhealth/petl:latest
    affected
    assert_success
    assert_equal "$(output_of)" "affected=true"
}

@test "a project on the snapshot tag that moved is affected" {
    dockerfile partnersinhealth/petl:3.8.0-SNAPSHOT
    affected
    assert_equal "$(output_of)" "affected=true"
}

@test "an image with no tag is latest" {
    dockerfile partnersinhealth/petl
    affected
    assert_equal "$(output_of)" "affected=true"
}

@test "a project pinned to another version isn't affected" {
    dockerfile partnersinhealth/petl:3.7.0
    affected
    assert_success
    assert_equal "$(output_of)" "affected=false"
    assert_output --partial "3.7.0"
}

@test "a project pinned by digest isn't affected" {
    dockerfile 'partnersinhealth/petl:latest@sha256:0123456789abcdef'
    affected
    assert_equal "$(output_of)" "affected=false"
}

@test "a project on another image isn't affected" {
    dockerfile someone/petl:latest
    affected
    assert_equal "$(output_of)" "affected=false"
}

@test "quotes around the default are fine" {
    dockerfile '"partnersinhealth/petl:latest"'
    affected
    assert_equal "$(output_of)" "affected=true"
}

@test "a Dockerfile without the build arg is an error" {
    printf 'FROM partnersinhealth/petl:latest\n' > "$BATS_TEST_TMPDIR/Dockerfile"
    affected
    assert_failure
    assert_output --partial "no ARG PETL_BASE_IMAGE="
}

@test "no published tags is an error" {
    dockerfile partnersinhealth/petl:latest
    affected '[]'
    assert_failure
    assert_output --partial "no published tags"
}
