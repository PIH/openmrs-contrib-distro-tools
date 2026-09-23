#!/usr/bin/env bats
# wait-for-healthy returns as soon as the outcome is known, rather than always polling the timeout.

load ../helpers

teardown() { common_teardown; }

start() { # <health command> [docker run args...]
    local cmd=$1; shift
    docker run -d --name "$(res c)" --health-cmd "$cmd" --health-interval 1s --health-retries 1 "$@" \
        alpine:3.21 sleep 300 >/dev/null
}

@test "succeeds once the container reports healthy" {
    start true
    run "$UTILS/wait-for-healthy.sh" --container="$(res c)" --timeout=60
    assert_success
    assert_output --partial 'is healthy'
}

@test "fails fast when the container exits, well before the timeout" {
    docker run -d --name "$(res c)" --health-cmd true alpine:3.21 true >/dev/null
    SECONDS=0
    run "$UTILS/wait-for-healthy.sh" --container="$(res c)" --timeout=120
    assert_failure
    assert_output --partial 'exited unexpectedly'
    assert [ "$SECONDS" -lt 30 ]
}

@test "with --fail-on-unhealthy=true, fails as soon as the container reports unhealthy" {
    start false
    SECONDS=0
    run "$UTILS/wait-for-healthy.sh" --container="$(res c)" --timeout=120 --fail-on-unhealthy=true
    assert_failure
    assert_output --partial 'reported unhealthy'
    assert [ "$SECONDS" -lt 30 ]
}

@test "by default keeps waiting through unhealthy, then times out" {
    start false
    run "$UTILS/wait-for-healthy.sh" --container="$(res c)" --timeout=10
    assert_failure
    assert_output --partial 'timed out after 10s'
}

@test "rejects a container that doesn't exist" {
    run "$UTILS/wait-for-healthy.sh" --container="$(res missing)"
    assert_failure
    assert_output --partial 'no such container'
}
