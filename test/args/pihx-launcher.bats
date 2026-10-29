#!/usr/bin/env bats
# bin/pihx, the launcher: runs the pihx package from its checkout inside pihx-runtime, tagged by the
# content hash of images/pihx-runtime.

load ../helpers

# Builds pihx-runtime once, so the tests don't race to build it.
setup_file() { "$BIN/pihx" version >/dev/null; }

setup() {
    cd "$BATS_TEST_TMPDIR"
    export PIHX_HOME="$BATS_TEST_TMPDIR/home"
}
teardown() { common_teardown; }

# A copy of the checkout at <dir>. images/ is copied as is, so it shares pihx-runtime's tag.
copy_tools() { # <dir>
    mkdir -p "$1"
    cp -R "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$REPO_ROOT/images" "$REPO_ROOT/pihx" "$1"
}

@test "image-tag is stable and changes with content" {
    mkdir -p d/sub
    echo a > d/a; echo b > d/sub/b
    run "$REPO_ROOT/lib/image-tag.sh" d
    assert_success
    assert_output --regexp '^[0-9a-f]{12}$'
    first=$output

    run "$REPO_ROOT/lib/image-tag.sh" d
    assert_output "$first"

    # Same content, created in the other order with other mtimes.
    mkdir -p e/sub
    echo b > e/sub/b; touch -d '2001-01-01' e/sub/b; echo a > e/a
    run "$REPO_ROOT/lib/image-tag.sh" e
    assert_output "$first"

    echo changed > d/sub/b
    run "$REPO_ROOT/lib/image-tag.sh" d
    assert_success
    refute_output "$first"
}

@test "pihx version prints a version and exits 0" {
    run "$BIN/pihx" version
    assert_success
    assert_output --regexp '^pihx [0-9]+\.[0-9]+'
}

@test "exit status is passed through" {
    run "$BIN/pihx" nosuch status
    assert_failure
    assert_output --partial 'error:'
}

@test "files pihx writes are owned by the caller" {
    # A copy whose entry point writes into PIHX_HOME, to check the uid it runs as.
    copy_tools tools
    printf '%s\n' 'import os' \
        'open(os.path.join(os.environ["PIHX_HOME"], "written"), "w").close()' > tools/pihx/__main__.py
    run tools/bin/pihx version
    assert_success
    assert [ -f "$PIHX_HOME/written" ]
    assert_equal "$(stat -c %u:%g "$PIHX_HOME/written")" "$(id -u):$(id -g)"
}

@test "works from a directory outside the mounted paths" {
    cd /tmp
    run "$BIN/pihx" version
    assert_success
    assert_output --regexp '^pihx [0-9]+\.[0-9]+'

    # Docker makes a missing -w directory, so check where pihx actually runs: / outside the mounted
    # paths, the caller's directory inside them; PIHX_CWD is the host's either way.
    cd "$BATS_TEST_TMPDIR"
    copy_tools tools
    printf '%s\n' 'import os' 'print(os.getcwd(), os.environ["PIHX_CWD"])' > tools/pihx/__main__.py
    mkdir -p "$PIHX_HOME/sub"
    run tools/bin/pihx
    assert_output "/ $(pwd -P)"
    cd "$PIHX_HOME/sub"
    run "$BATS_TEST_TMPDIR/tools/bin/pihx"
    assert_output "$(pwd -P) $(pwd -P)"
}

@test "hands off to the instance's own tools" {
    copy_tools a
    copy_tools b
    b=$(cd -P b && pwd)
    mkdir -p "$PIHX_HOME/inst"
    ln -s "$b" "$PIHX_HOME/inst/tools"
    run a/bin/pihx inst version
    assert_success
    assert_output --partial "tools: $b"
}
