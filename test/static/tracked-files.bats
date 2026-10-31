#!/usr/bin/env bats
# Build artifacts are never tracked: a dirty checkout makes Puppet refuse the instance.

load ../helpers

@test "no compiled Python is tracked" {
    command -v git >/dev/null || skip "needs git"
    run git -C "$REPO_ROOT" ls-files -- '*.pyc' '*/__pycache__/*'
    assert_success
    assert_output ''
}
