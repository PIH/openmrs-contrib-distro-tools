#!/usr/bin/env bats
# Every shell script in the project passes shellcheck at warning level or above.

load ../helpers

run_shellcheck() {
    if type -P shellcheck >/dev/null; then
        shellcheck "$@"
    else
        docker run --rm -v "$REPO_ROOT:/mnt:ro" -w /mnt koalaman/shellcheck-alpine:stable shellcheck "$@"
    fi
}

scripts() {
    (cd "$REPO_ROOT" && ls bin/* utils/*.sh docker/*.sh test/run)
}

@test "all shell scripts pass shellcheck" {
    cd "$REPO_ROOT"
    run run_shellcheck -S warning $(scripts)
    assert_success
}

@test "test helpers pass shellcheck" {
    cd "$REPO_ROOT"
    run run_shellcheck -S warning -s bash test/helpers.bash
    assert_success
}
