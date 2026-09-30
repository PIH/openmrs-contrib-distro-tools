#!/usr/bin/env bats
# runtime-properties sets keys in, or sets aside, a data directory's openmrs-runtime.properties.

load ../helpers

setup() {
    VOL="$(res data)"
    docker volume create "$VOL" >/dev/null
    docker run --rm -v "$VOL:/v" alpine:3.21 sh -c '
        printf "a=1\n  connection.password = old\nconnection.username:olduser\n#connection.password=comment\n" > /v/openmrs-runtime.properties
        chown 123:456 /v/openmrs-runtime.properties && chmod 640 /v/openmrs-runtime.properties'
}
teardown() { common_teardown; }

in_volume() { # <command>
    docker run --rm -v "$VOL:/v" alpine:3.21 sh -c "$1"
}

@test "--set replaces the given keys' lines, doubling backslashes, and keeps the owner, mode and a backup" {
    run "$UTILS/runtime-properties.sh" --volume="$VOL" --set <<< "$(printf 'connection.username=%s\nconnection.password=%s' newuser 'p\w=x')"
    assert_success
    assert_output --partial "Set connection.username and connection.password"
    run in_volume 'cat /v/openmrs-runtime.properties'
    assert_output "$(printf 'a=1\n#connection.password=comment\nconnection.username=newuser\nconnection.password=p\\\\w=x')"
    run in_volume 'stat -c "%u:%g %a" /v/openmrs-runtime.properties; grep -c old /v/openmrs-runtime.properties.bak'
    assert_output "$(printf '123:456 640\n2')"
}

@test "--set-aside renames the file, and does nothing without one" {
    run "$UTILS/runtime-properties.sh" --volume="$VOL" --set-aside
    assert_success
    assert_output --partial 'Moved openmrs-runtime.properties aside'
    run in_volume 'ls /v'
    assert_output openmrs-runtime.properties.restored
    run "$UTILS/runtime-properties.sh" --volume="$VOL" --set-aside
    assert_success
    assert_output ''
}

@test "needs one of --set-aside and --set, and an existing volume" {
    run "$UTILS/runtime-properties.sh" --volume="$VOL"
    assert_failure
    assert_output --partial Usage:
    run "$UTILS/runtime-properties.sh" --volume="$(res nope)" --set-aside
    assert_failure
    assert_output --partial 'no such volume'
}
