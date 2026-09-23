#!/usr/bin/env bats
# openmrs-utils is a passthrough to utils/<name>.sh: same args, same output, same exit code.

load ../helpers

setup() { cd "$BATS_TEST_TMPDIR"; }
teardown() { common_teardown; }

@test "with no arguments, lists every utils script and fails" {
    run "$BIN/openmrs-utils"
    assert_failure
    for script in backup-mysqldump backup-openmrs-data-directory backup-percona convert-percona-backup \
        extract-archive strip-mysqldump-definers clear-configuration-checksums wait-for-healthy; do
        assert_output --partial "  $script"
    done
}

@test "rejects an unknown script name" {
    run "$BIN/openmrs-utils" no-such-script
    assert_failure
    assert_output --partial 'no such utility script: no-such-script'
}

@test "passes arguments, output and success through to the script" {
    touch plain.sql
    run "$BIN/openmrs-utils" extract-archive --path=plain.sql
    assert_success
    assert_output plain.sql
}

@test "passes a failing exit code through from the script" {
    run "$BIN/openmrs-utils" extract-archive --path=nope.7z
    assert_failure
    assert_output --partial 'no such file or directory: nope.7z'
}
