#!/usr/bin/env bats
# The gate steps of deploy-via-runner.yml and run-petl-via-runner.yml: the host pause, instance holds, and the
# puppet-apply.sh options a deploy passes. Runs each step's script from the workflow file, with PUPPET_DIR pointing at
# a temporary directory instead of /etc/puppet.

load ../helpers

setup() {
    export PUPPET_DIR="$BATS_TEST_TMPDIR/puppet" GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output"
    mkdir -p "$PUPPET_DIR"
    : > "$GITHUB_OUTPUT"
    export RUNNER_LABEL=appclstr-01 MANIFEST=site
}

# Prints the run: script of step <id> in job <job> of workflow <file>.
step_script() { # <file> <job> <id>
    python3 -c 'import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
print(next(s["run"] for s in w["jobs"][sys.argv[2]]["steps"] if s.get("id") == sys.argv[3]))' \
        "$REPO_ROOT/.github/workflows/$1" "$2" "$3"
}
deploy_gate() { # env INSTANCES, HOST
    run bash -c "$(step_script deploy-via-runner.yml deploy gate)"
}
petl_gate() { # env INSTANCE
    run bash -c "$(step_script run-petl-via-runner.yml run-petl gate)"
}
outputs() { cat "$GITHUB_OUTPUT"; }

@test "defaults: host and every instance, as before" {
    INSTANCES=all HOST=true deploy_gate
    assert_success
    run outputs
    assert_line "args="
    refute_line "disabled=true"
}

@test "one instance, instance only" {
    INSTANCES=ces-ci HOST=false deploy_gate
    assert_success
    run outputs
    assert_line "args=--instance ces-ci --no-host"
}

@test "host only" {
    INSTANCES=none HOST=true deploy_gate
    assert_success
    run outputs
    assert_line "args=--no-instances"
}

@test "rejects bad instances before anything runs" {
    for bad in 'ces-ci --no-host' '$(id)' 'CES' ''; do
        INSTANCES="$bad" HOST=true deploy_gate
        assert_failure
        assert_output --partial "::error::"
    done
    INSTANCES=none HOST=false deploy_gate
    assert_failure
    assert_output --partial "applies nothing"
    run outputs
    refute_output --partial "args="
}

@test "host pause skips everything" {
    echo "maintenance" > "$PUPPET_DIR/build-disabled"
    INSTANCES=ces-ci HOST=false deploy_gate
    assert_success
    assert_output --partial "::warning::Deploy skipped: $PUPPET_DIR/build-disabled present on appclstr-01"
    assert_output --partial "maintenance"
    run outputs
    assert_line "disabled=true"
}

@test "a held target skips the whole deploy, host too" {
    echo "restore in progress" > "$PUPPET_DIR/build-disabled-ces-ci"
    INSTANCES=ces-ci HOST=true deploy_gate
    assert_success
    assert_output --partial "::warning::Deploy skipped: ces-ci held by $PUPPET_DIR/build-disabled-ces-ci on appclstr-01"
    assert_output --partial "restore in progress"
    run outputs
    assert_line "disabled=true"
}

@test "all: warns per held instance and still deploys" {
    touch "$PUPPET_DIR/build-disabled-ces-ci" "$PUPPET_DIR/build-disabled-kol-ci"
    INSTANCES=all HOST=true deploy_gate
    assert_success
    assert_output --partial "::warning::ces-ci held by $PUPPET_DIR/build-disabled-ces-ci"
    assert_output --partial "::warning::kol-ci held by $PUPPET_DIR/build-disabled-kol-ci"
    assert_output --partial "No reason given."
    run outputs
    refute_line "disabled=true"
    assert_line "args="
}

@test "all: files that can't be holds aren't reported as held" {
    touch "$PUPPET_DIR/build-disabled-ces-ci~" "$PUPPET_DIR/build-disabled-" "$PUPPET_DIR/build-disabled-Old"
    INSTANCES=all HOST=true deploy_gate
    assert_success
    refute_output --partial "::warning::"
}

@test "instances and host need the site manifest" {
    MANIFEST=petl INSTANCES=ces-ci HOST=false deploy_gate
    assert_failure
    assert_output --partial "::error::instances and host apply only to the site manifest"
    MANIFEST=petl INSTANCES=all HOST=true deploy_gate
    assert_success
    run outputs
    assert_line "args="
}

@test "all, no holds: no warnings" {
    INSTANCES=all HOST=true deploy_gate
    assert_success
    refute_output --partial "::warning::"
}

@test "a hold on another instance doesn't affect a deploy for this one" {
    touch "$PUPPET_DIR/build-disabled-kol-ci"
    INSTANCES=ces-ci HOST=false deploy_gate
    assert_success
    refute_output --partial "::warning::"
    run outputs
    assert_line "args=--instance ces-ci --no-host"
}

@test "PETL run skips a held instance" {
    touch "$PUPPET_DIR/build-disabled-ces-ci"
    INSTANCE=ces-ci petl_gate
    assert_success
    assert_output --partial "::warning::PETL run skipped: ces-ci held by $PUPPET_DIR/build-disabled-ces-ci"
    run outputs
    assert_line "disabled=true"
}

@test "PETL run skips while the host is paused" {
    touch "$PUPPET_DIR/build-disabled"
    INSTANCE=ces-ci petl_gate
    assert_success
    assert_output --partial "::warning::PETL run skipped: $PUPPET_DIR/build-disabled present"
}

@test "PETL run goes ahead otherwise" {
    touch "$PUPPET_DIR/build-disabled-kol-ci"
    INSTANCE=ces-ci petl_gate
    assert_success
    refute_output --partial "::warning::"
    run outputs
    refute_output --partial "disabled=true"
}

@test "PETL run rejects a bad instance name" {
    INSTANCE='x; id' petl_gate
    assert_failure
}
