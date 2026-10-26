#!/usr/bin/env bats
# backup-pgdump rejects bad input before touching any container, and never leaves a file behind.

load ../helpers

setup() { cd "$BATS_TEST_TMPDIR"; }
teardown() { common_teardown; }

@test "requires --container and --output" {
    run "$UTILS/backup-pgdump.sh" --output=out.sql
    assert_failure
    assert_output --partial Usage:
    run "$UTILS/backup-pgdump.sh" --container=db
    assert_failure
    assert_output --partial Usage:
}

@test "refuses an output not ending in .sql, .gz or .7z" {
    run "$UTILS/backup-pgdump.sh" --container=db --output=out.txt
    assert_failure
    assert_output --partial 'must end in .sql, .gz or .7z'
    assert [ ! -e out.txt ]
}

@test "a .7z output requires ARCHIVE_PASSWORD" {
    run env -u ARCHIVE_PASSWORD "$UTILS/backup-pgdump.sh" --container=db --output=out.sql.7z
    assert_failure
    assert_output --partial ARCHIVE_PASSWORD
}

@test "refuses .gz.7z" {
    ARCHIVE_PASSWORD=x run "$UTILS/backup-pgdump.sh" --container=db --output=out.sql.gz.7z
    assert_failure
    assert_output --partial '.gz.7z'
}
