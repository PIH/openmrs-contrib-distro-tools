#!/usr/bin/env bats
# backup-percona / convert-percona-backup input handling, and that a failed backup leaves nothing
# behind that could be mistaken for a real one.

load ../helpers

setup() { cd "$BATS_TEST_TMPDIR"; }
teardown() { common_teardown; }

@test "backup-percona requires --container, --volume and --output" {
    run "$UTILS/backup-percona.sh" --volume=v --output=out
    assert_failure
    assert_output --partial usage
    run "$UTILS/backup-percona.sh" --container=c --output=out
    assert_failure
    assert_output --partial usage
    run "$UTILS/backup-percona.sh" --container=c --volume=v
    assert_failure
    assert_output --partial usage
}

@test "backup-percona refuses an output directory that already exists" {
    mkdir out
    touch out/keep
    run "$UTILS/backup-percona.sh" --container=c --volume=v --output=out
    assert_failure
    assert_output --partial 'already exists'
    assert [ -e out/keep ]
}

@test "a failed backup-percona leaves no output directory behind" {
    run "$UTILS/backup-percona.sh" --container="$(res no-such-container)" --volume="$(res no-such-volume)" --output=out
    assert_failure
    assert [ ! -e out ]
}

@test "convert-percona-backup requires --backup-dir and --output-dir" {
    run "$UTILS/convert-percona-backup.sh" --output-dir=out
    assert_failure
    assert_output --partial usage
    run "$UTILS/convert-percona-backup.sh" --backup-dir=in
    assert_failure
    assert_output --partial usage
}

@test "convert-percona-backup rejects a backup dir that doesn't exist" {
    run "$UTILS/convert-percona-backup.sh" --backup-dir=nope --output-dir=out
    assert_failure
    assert_output --partial 'no such directory'
    assert [ ! -e out ]
}

@test "convert-percona-backup refuses an output directory that already exists" {
    mkdir in out
    run "$UTILS/convert-percona-backup.sh" --backup-dir=in --output-dir=out
    assert_failure
    assert_output --partial 'already exists'
}
