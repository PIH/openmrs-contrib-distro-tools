#!/usr/bin/env bats
# backup-mysqldump rejects bad input before touching any container, and never leaves a file behind.

load ../helpers

setup() { cd "$BATS_TEST_TMPDIR"; }
teardown() { common_teardown; }

@test "requires --container and --output" {
    run "$UTILS/backup-mysqldump.sh" --output=out.sql
    assert_failure
    assert_output --partial usage
    run "$UTILS/backup-mysqldump.sh" --container=db
    assert_failure
    assert_output --partial usage
}

@test "rejects an unknown argument" {
    run "$UTILS/backup-mysqldump.sh" --container=db --output=out.sql --bogus
    assert_failure
    assert_output --partial 'unknown argument: --bogus'
}

@test "rejects an output extension it can't produce" {
    run "$UTILS/backup-mysqldump.sh" --container=db --output=out.txt
    assert_failure
    assert_output --partial 'must end in .sql, .gz or .7z'
    assert [ ! -e out.txt ]
}

@test "rejects .gz.7z, since 7z already compresses" {
    ARCHIVE_PASSWORD=pw run "$UTILS/backup-mysqldump.sh" --container=db --output=out.sql.gz.7z
    assert_failure
    assert_output --partial 'use .sql.7z instead'
    assert [ ! -e out.sql.gz.7z ]
}

@test "requires ARCHIVE_PASSWORD for .7z output" {
    run env -u ARCHIVE_PASSWORD "$UTILS/backup-mysqldump.sh" --container=db --output=out.sql.7z
    assert_failure
    assert_output --partial 'ARCHIVE_PASSWORD must be set'
    assert [ ! -e out.sql.7z ]
}

@test "refuses to overwrite an existing output file" {
    echo original > out.sql
    run "$UTILS/backup-mysqldump.sh" --container=db --output=out.sql
    assert_failure
    assert_output --partial 'already exists'
    assert_equal "$(cat out.sql)" original
}

@test "a failed dump leaves no partial output file" {
    run "$UTILS/backup-mysqldump.sh" --container="$(res no-such-container)" --output=out.sql.gz
    assert_failure
    assert [ ! -e out.sql.gz ]
}
