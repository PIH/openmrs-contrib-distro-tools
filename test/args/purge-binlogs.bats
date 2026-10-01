#!/usr/bin/env bats
# purge-binlogs input handling.

load ../helpers

teardown() { common_teardown; }

@test "requires --container or --host" {
    run "$UTILS/purge-binlogs.sh"
    assert_failure
    assert_output --partial Usage:
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

@test "the MySQL utilities need MYSQL_PASSWORD, and take MYSQL_ROOT_PASSWORD with a warning" {
    run env -u MYSQL_PASSWORD -u MYSQL_ROOT_PASSWORD "$UTILS/purge-binlogs.sh" --container="$(res nope)"
    assert_failure
    assert_output --partial 'MYSQL_PASSWORD must be set: the password for --user (root)'
    run env -u MYSQL_PASSWORD -u MYSQL_ROOT_PASSWORD "$UTILS/fingerprint.sh" --container="$(res nope)" --user=reader
    assert_failure
    assert_output --partial 'MYSQL_PASSWORD must be set: the password for --user (reader)'
    run env -u MYSQL_PASSWORD MYSQL_ROOT_PASSWORD=x "$UTILS/fingerprint.sh" --container="$(res nope)"
    assert_failure
    assert_output --partial 'MYSQL_ROOT_PASSWORD is deprecated here'
    assert_output --partial "can't reach container"
}
