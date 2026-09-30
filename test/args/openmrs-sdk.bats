#!/usr/bin/env bats
# openmrs-sdk argument handling (nothing here runs Maven).

load ../helpers

setup() { cd "$BATS_TEST_TMPDIR"; }

@test "requires a command and a server id" {
    run "$BIN/openmrs-sdk"
    assert_failure
    assert_output --partial Usage
    run env -u SERVER_ID "$BIN/openmrs-sdk" create
    assert_failure
    assert_output --partial Usage
}

@test "rejects an unknown flag, with the server id positional or from SERVER_ID" {
    run "$BIN/openmrs-sdk" create myserver --bogus
    assert_failure
    assert_output --partial "Unknown argument: '--bogus'"
    SERVER_ID=myserver run "$BIN/openmrs-sdk" create --bogus
    assert_failure
    assert_output --partial "Unknown argument: '--bogus'"
}
