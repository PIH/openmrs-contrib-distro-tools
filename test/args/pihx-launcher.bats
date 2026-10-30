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
    cp -R "$REPO_ROOT/bin" "$REPO_ROOT/utils" "$REPO_ROOT/images" "$REPO_ROOT/pihx" "$1"
}

@test "hash-directory is stable and changes with content" {
    mkdir -p d/sub
    echo a > d/a; echo b > d/sub/b
    run "$REPO_ROOT/utils/hash-directory.sh" d
    assert_success
    assert_output --regexp '^[0-9a-f]{12}$'
    first=$output

    run "$REPO_ROOT/utils/hash-directory.sh" d
    assert_output "$first"

    # Same content, created in the other order with other mtimes.
    mkdir -p e/sub
    echo b > e/sub/b; touch -d '2001-01-01' e/sub/b; echo a > e/a
    run "$REPO_ROOT/utils/hash-directory.sh" e
    assert_output "$first"

    echo changed > d/sub/b
    run "$REPO_ROOT/utils/hash-directory.sh" d
    assert_success
    refute_output "$first"
}

@test "hash-directory fails on a file it can't read, rather than print a hash" {
    [ "$(id -u)" -ne 0 ] || skip "root reads any file"
    mkdir d
    echo a > d/a; echo b > d/b
    chmod 000 d/b
    run "$REPO_ROOT/utils/hash-directory.sh" d
    chmod 600 d/b
    assert_failure
    assert_line --index 1 "error: can't read d/b"
    refute_output --regexp '^[0-9a-f]{12}$'
}

@test "hash-directory fails when the hash comes out empty" {
    mkdir d bin
    echo a > d/a
    printf '#!/bin/sh\ncat >/dev/null\n' > bin/sha256sum
    chmod +x bin/sha256sum
    PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$REPO_ROOT/utils/hash-directory.sh" d
    assert_failure
    assert_output --partial "error: no hash for d/a"
    refute_output --regexp '^[0-9a-f]{12}$'
}

@test "the launcher runs pihx under an init process, so Ctrl-C reaches it" {
    run grep -c 'docker run --rm -i --init' "$BIN/pihx"
    assert_output 2
}

@test "pihx version prints a version and exits 0" {
    run "$BIN/pihx" version
    assert_success
    assert_output --regexp '^pihx [0-9]+\.[0-9]+'
}

@test "exit status is passed through" {
    run "$BIN/pihx" nosuch status
    assert_failure 2
    assert_output --partial "error: no instance 'nosuch'"
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

@test "a runtime image that fails to build ends with an error line" {
    copy_tools tools
    echo 'RUN exit 3' >> tools/images/pihx-runtime/Dockerfile
    run tools/bin/pihx version
    assert_failure
    assert_line --index -1 --regexp '^error: couldn.t build partnersinhealth/pihx-runtime:[0-9a-f]{12}$'
}

@test "a non-local DOCKER_HOST is refused" {
    DOCKER_HOST=tcp://127.0.0.1:2375 run "$BIN/pihx" version
    assert_failure
    assert_output 'error: pihx needs a local Docker socket; DOCKER_HOST is tcp://127.0.0.1:2375'

    # A unix:// one is used as the socket.
    DOCKER_HOST=unix:///var/run/docker.sock run "$BIN/pihx" version
    assert_success
}

@test "the caller's registry credentials reach the container, without credential helpers" {
    # A fake credential; the probe prints only the config's keys.
    export DOCKER_CONFIG="$BATS_TEST_TMPDIR/docker-config"
    mkdir -p "$DOCKER_CONFIG"
    printf '%s' '{"auths": {"ghcr.io": {"auth": "ZmFrZTpmYWtl"}}, "credsStore": "desktop",' \
        ' "credHelpers": {"gcr.io": "gcloud"}}' > "$DOCKER_CONFIG/config.json"
    copy_tools tools
    printf '%s\n' 'import json, os' 'from pihx import cli' 'cli.main(["version"])' \
        'path = os.path.join(os.environ["HOME"], ".docker", "config.json")' \
        'config = json.load(open(path))' \
        'print("keys:", sorted(config), "auths:", sorted(config["auths"]))' \
        'print("docker dir writable:", os.access(os.path.dirname(path), os.W_OK))' \
        > tools/pihx/__main__.py
    run tools/bin/pihx
    assert_success
    assert_line "keys: ['auths'] auths: ['ghcr.io']"
    assert_line "docker dir writable: True"
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

    # Hands off once only, so links can't loop.
    a=$(cd -P a && pwd)
    PIHX_HANDED_OFF=1 run a/bin/pihx inst version
    assert_success
    assert_output --partial "tools: $a"
}

@test "every caller variable reaches pihx by name, except the container's own settings" {
    copy_tools tools
    printf '%s\n' 'import os' 'e = os.environ' \
        'print("custom:", e.get("PETL_MYSQL_PASSWORD"), e.get("ZZ_ANYTHING"))' \
        'print("home:", e["HOME"], "pythonpath:", e["PYTHONPATH"])' > tools/pihx/__main__.py
    PETL_MYSQL_PASSWORD='s3 cr$t' ZZ_ANYTHING=x PYTHONPATH=/nonexistent HOME=/caller \
        run tools/bin/pihx
    assert_success
    assert_line 'custom: s3 cr$t x'
    assert_line "home: /tmp pythonpath: $(cd -P tools && pwd)"
}

@test "values are passed by name, so they aren't on the docker command line" {
    # A docker in front of the real one, recording its arguments.
    mkdir bin
    printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$@" >> "$RECORD"' \
        "exec $(command -v docker) \"\$@\"" > bin/docker
    chmod +x bin/docker
    RECORD="$BATS_TEST_TMPDIR/args" PATH="$BATS_TEST_TMPDIR/bin:$PATH" PETL_MYSQL_PASSWORD=sekrit-value \
        run "$BIN/pihx" version
    assert_success
    run grep -c sekrit-value "$BATS_TEST_TMPDIR/args"
    assert_output 0
    run grep -x PETL_MYSQL_PASSWORD "$BATS_TEST_TMPDIR/args"
    assert_success
}

@test "an instance with no tools directory is an error naming use-tools" {
    mkdir -p "$PIHX_HOME/inst"
    ln -s "$BATS_TEST_TMPDIR/gone" "$PIHX_HOME/inst/tools"
    run "$BIN/pihx" inst version
    assert_failure
    assert_output "error: $PIHX_HOME/inst/tools is missing; point it at a tools directory with: pihx inst use-tools <dir>"
}
