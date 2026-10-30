#!/usr/bin/env bats
# pihx create, list, config, add-service, remove-service and use-tools, black-box through bin/pihx.
# Nothing here starts a container: create only has Compose check the instance (config -q).

load ../helpers

setup_file() { "$BIN/pihx" version >/dev/null; }

setup() {
    cd "$BATS_TEST_TMPDIR"
    export PIHX_HOME="$BATS_TEST_TMPDIR/home"
    # Nothing from the test runner's environment (helpers.bash exports some) is this test's input.
    unset OPENMRS_IMAGE_NAME OPENMRS_DB_PORT OPENMRS_HTTP_PORT OPENMRS_DB_OPT_innodb_buffer_pool_size
}
teardown() { common_teardown; }

@test "create writes only values the caller set" {
    OPENMRS_DB_PASSWORD='p $w#d' TZ=Africa/Kigali UNRELATED_VAR=nope \
        run "$BIN/pihx" kz create --services=openmrs-db
    assert_success
    assert_equal "$(cat "$PIHX_HOME/kz/openmrs-db.env")" "OPENMRS_DB_PASSWORD='p \$w#d'"
    assert_equal "$(cat "$PIHX_HOME/kz/instance.env")" "TZ='Africa/Kigali'"
    run grep -rl UNRELATED_VAR "$PIHX_HOME/kz"
    assert_failure
    assert_equal "$(readlink "$PIHX_HOME/kz/tools")" "$REPO_ROOT"
    # The files hold secrets.
    assert_equal "$(stat -c %a "$PIHX_HOME/kz/openmrs-db.env")" 600
    assert_equal "$(stat -c %a "$PIHX_HOME/kz/instance.env")" 600
}

@test "create captures a required value that has no default, and a capture-env prefix" {
    OPENMRS_IMAGE_NAME=example/openmrs OMRS_EXTRA_FOO=bar \
        run "$BIN/pihx" kz create --services=openmrs-db,openmrs
    assert_success
    run cat "$PIHX_HOME/kz/openmrs.env"
    assert_line "OPENMRS_IMAGE_NAME='example/openmrs'"
    assert_line "OMRS_EXTRA_FOO='bar'"
}

@test "create refuses when a required value is missing and leaves nothing behind" {
    run "$BIN/pihx" kz create --services=openmrs-db,openmrs
    assert_failure
    assert_line --index -1 --partial 'error:'
    assert_output --partial OPENMRS_IMAGE_NAME
    assert [ ! -e "$PIHX_HOME/kz" ]
}

@test "create refuses a service whose requires is missing" {
    OPENMRS_IMAGE_NAME=example/openmrs run "$BIN/pihx" kz create --services=openmrs
    assert_failure
    assert_line --index -1 'error: openmrs requires openmrs-db: add it to the instance too'
    assert [ ! -e "$PIHX_HOME/kz" ]
}

@test "create refuses an existing directory" {
    mkdir -p "$PIHX_HOME/kz"
    run "$BIN/pihx" kz create --services=openmrs-db
    assert_failure
    assert_output --partial 'already exists'
}

@test "config masks secrets" {
    OPENMRS_DB_PASSWORD=hunter2 "$BIN/pihx" kz create --services=openmrs-db
    run "$BIN/pihx" kz config
    assert_success
    refute_output --partial hunter2
    assert_line 'OPENMRS_DB_PASSWORD=********'
    assert_line 'OPENMRS_DB_USER=openmrs'

    run "$BIN/pihx" kz config --show-secrets
    assert_success
    assert_line 'OPENMRS_DB_PASSWORD=hunter2'
}

@test "add-service and remove-service change the instance's env files" {
    "$BIN/pihx" kz create --services=openmrs-db
    OPENMRS_IMAGE_NAME=example/openmrs run "$BIN/pihx" kz add-service openmrs
    assert_success
    assert_equal "$(cat "$PIHX_HOME/kz/openmrs.env")" "OPENMRS_IMAGE_NAME='example/openmrs'"

    # openmrs needs the database, so the database stays while openmrs is there.
    run "$BIN/pihx" kz remove-service openmrs-db
    assert_failure
    assert_line --index -1 'error: openmrs requires openmrs-db: remove it first'

    run "$BIN/pihx" kz remove-service openmrs
    assert_success
    assert [ ! -e "$PIHX_HOME/kz/openmrs.env" ]
    run "$BIN/pihx" list
    assert_success
    assert_line --regexp "^kz +openmrs-db +$REPO_ROOT\$"
}

@test "an instance with no tools directory is an error naming use-tools" {
    "$BIN/pihx" kz create --services=openmrs-db
    ln -sfn "$BATS_TEST_TMPDIR/moved" "$PIHX_HOME/kz/tools"
    run "$BIN/pihx" kz config
    assert_failure
    assert_line --index -1 --partial "$PIHX_HOME/kz/tools"
    assert_line --index -1 --partial "pihx kz use-tools <dir>"
    # list still works, and shows the link as written.
    run "$BIN/pihx" list
    assert_success
    assert_line --regexp "^kz +openmrs-db +$BATS_TEST_TMPDIR/moved\$"
    # use-tools is the fix, so it isn't stopped by it.
    run "$BIN/pihx" kz use-tools "$REPO_ROOT"
    assert_success
    run "$BIN/pihx" kz config
    assert_success
}

@test "use-tools moves the instance to another tools directory" {
    "$BIN/pihx" kz create --services=openmrs-db
    mkdir other
    cp -R "$REPO_ROOT/bin" "$REPO_ROOT/utils" "$REPO_ROOT/images" "$REPO_ROOT/pihx" \
        "$REPO_ROOT/services" "$REPO_ROOT/instance.env.defaults" other
    other=$(cd -P other && pwd)
    # A relative path, to a checkout outside the mounted paths.
    run "$BIN/pihx" kz use-tools other
    assert_success
    assert_equal "$(readlink "$PIHX_HOME/kz/tools")" "$other"
    run "$BIN/pihx" kz version
    assert_success
    assert_output --partial "tools: $other"

    run "$BIN/pihx" kz use-tools "$BATS_TEST_TMPDIR"
    assert_failure
    assert_output --partial "isn't a tools directory"
}

@test "use-tools resolves a path through a link or .. outside the mounted paths" {
    "$BIN/pihx" kz create --services=openmrs-db
    mkdir -p real other/sub
    cp -R "$REPO_ROOT/bin" "$REPO_ROOT/utils" "$REPO_ROOT/images" "$REPO_ROOT/pihx" \
        "$REPO_ROOT/services" "$REPO_ROOT/instance.env.defaults" real
    real=$(cd -P real && pwd)
    ln -s "$real" alias
    run "$BIN/pihx" kz use-tools other/sub/../../alias
    assert_success
    assert_equal "$(readlink "$PIHX_HOME/kz/tools")" "$real"
}

@test "use-tools refuses to replace a tools directory" {
    "$BIN/pihx" kz create --services=openmrs-db
    # As on a Puppet host: the checkout itself.
    rm "$PIHX_HOME/kz/tools"
    mkdir "$PIHX_HOME/kz/tools"
    cp -R "$REPO_ROOT/bin" "$REPO_ROOT/utils" "$REPO_ROOT/images" "$REPO_ROOT/pihx" \
        "$REPO_ROOT/services" "$REPO_ROOT/instance.env.defaults" "$PIHX_HOME/kz/tools"
    run "$BIN/pihx" kz use-tools "$REPO_ROOT"
    assert_failure
    assert_line --index -1 --partial "is a directory of its own"
}
