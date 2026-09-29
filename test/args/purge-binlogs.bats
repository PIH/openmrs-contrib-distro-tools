#!/usr/bin/env bats
# purge-binlogs input handling.

load ../helpers

teardown() { common_teardown; }

@test "requires --container or --host" {
    run "$UTILS/purge-binlogs.sh"
    assert_failure
    assert_output --partial usage
}

@test "rejects --container and --host together" {
    run "$UTILS/purge-binlogs.sh" --container=c --host=h
    assert_failure
    assert_output --partial 'not both'
}

@test "rejects an unknown argument" {
    run "$UTILS/purge-binlogs.sh" --container=c --bogus
    assert_failure
    assert_output --partial 'unknown argument: --bogus'
}
