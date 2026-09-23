#!/usr/bin/env bats
# backup-openmrs-data-directory rejects bad input before archiving anything, and never leaves a file
# (or a stray Docker volume) behind.

load ../helpers

setup() {
    cd "$BATS_TEST_TMPDIR"
    make_data_fixture "$BATS_TEST_TMPDIR/data"
}
teardown() { common_teardown; }

@test "requires --volume and --output" {
    run "$UTILS/backup-openmrs-data-directory.sh" --output=out.tar.gz
    assert_failure
    assert_output --partial usage
    run "$UTILS/backup-openmrs-data-directory.sh" --volume="$BATS_TEST_TMPDIR/data"
    assert_failure
    assert_output --partial usage
}

@test "rejects an unknown argument" {
    run "$UTILS/backup-openmrs-data-directory.sh" --volume="$BATS_TEST_TMPDIR/data" --output=out.tar.gz --bogus
    assert_failure
    assert_output --partial 'unknown argument: --bogus'
}

@test "rejects an output extension it can't produce" {
    run "$UTILS/backup-openmrs-data-directory.sh" --volume="$BATS_TEST_TMPDIR/data" --output=out.zip
    assert_failure
    assert_output --partial 'must end in .tar.gz, .tgz or .7z'
    assert [ ! -e out.zip ]
}

@test "requires ARCHIVE_PASSWORD for .7z output" {
    run env -u ARCHIVE_PASSWORD "$UTILS/backup-openmrs-data-directory.sh" --volume="$BATS_TEST_TMPDIR/data" --output=out.7z
    assert_failure
    assert_output --partial 'ARCHIVE_PASSWORD must be set'
    assert [ ! -e out.7z ]
}

@test "rejects a named volume that doesn't exist, without creating it" {
    local vol
    vol="$(res missing-volume)"
    run "$UTILS/backup-openmrs-data-directory.sh" --volume="$vol" --output=out.tar.gz
    assert_failure
    assert_output --partial "no such volume: $vol"
    run docker volume inspect "$vol"
    assert_failure
    assert [ ! -e out.tar.gz ]
}

@test "rejects a host directory that doesn't exist" {
    run "$UTILS/backup-openmrs-data-directory.sh" --volume="$BATS_TEST_TMPDIR/nope" --output=out.tar.gz
    assert_failure
    assert_output --partial 'no such directory'
    assert [ ! -e out.tar.gz ]
}

@test "refuses to overwrite an existing output file" {
    echo original > out.tar.gz
    run "$UTILS/backup-openmrs-data-directory.sh" --volume="$BATS_TEST_TMPDIR/data" --output=out.tar.gz
    assert_failure
    assert_output --partial 'already exists'
    assert_equal "$(cat out.tar.gz)" original
}
