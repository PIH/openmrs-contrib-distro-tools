#!/usr/bin/env bats
# openmrs-utils is a passthrough to utils/<name>.sh: same args, same output, same exit code.

load ../helpers

setup() { cd "$BATS_TEST_TMPDIR"; }
teardown() { common_teardown; }

@test "with no arguments, lists every utils script and fails" {
    run "$BIN/openmrs-utils"
    assert_failure
    local script
    for script in "$UTILS"/*.sh; do
        assert_output --partial "  $(basename "$script" .sh)"
    done
    # utils/lib/ holds helpers, not utilities.
    refute_output --partial '  common'
    refute_output --partial '  mysql'
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
