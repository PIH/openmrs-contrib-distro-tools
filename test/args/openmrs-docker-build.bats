#!/usr/bin/env bats
# openmrs-docker start --build: Maven (a stub here) builds the distribution in OPENMRS_DISTRO_DIR on
# the host, after the command is checked, and Compose builds the openmrs image from it (the
# directory is mounted for that). openmrs-db is replaced by a sleeping alpine, so nothing heavy runs.

load ../helpers

setup() {
    cd "$BATS_TEST_TMPDIR"
    NAME="$(instance)"
    DISTRO="$BATS_TEST_TMPDIR/distro"
    mkdir -p "$DISTRO"
    # A stub mvn: records its run, and "builds" a tiny image context, as the distribution's would be.
    mkdir -p bin
    cat > bin/mvn <<'SH'
#!/bin/sh
echo "$PWD $*" >> "$MVN_LOG"
mkdir -p distro/target/distro/web
echo built > distro/target/distro/web/marker
printf 'FROM alpine:3.21\nCOPY marker /marker\nCMD ["sleep", "300"]\n' > distro/target/distro/web/Dockerfile
SH
    chmod +x bin/mvn
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH" MVN_LOG="$BATS_TEST_TMPDIR/mvn.log"
    IMAGE="$(res openmrs)"
    OPENMRS_DISTRO_DIR="$DISTRO" OPENMRS_IMAGE_NAME="$IMAGE" create_instance "$NAME" 2>/dev/null
    cat > "$PIHX_HOME/$NAME/openmrs-db.override.yaml" <<'YAML'
services:
  openmrs-db:
    image: alpine:3.21
    entrypoint: ["sleep", "300"]
    healthcheck: !override
      test: ["CMD", "true"]
      interval: 1s
      retries: 3
  openmrs-db-accounts:
    image: alpine:3.21
    entrypoint: ["true"]
YAML
}
teardown() {
    remove_test_instance "$NAME"
    remove_images "$IMAGE"
    common_teardown
}

@test "start --build runs Maven in OPENMRS_DISTRO_DIR, then builds the openmrs image from it" {
    run "$BIN/openmrs-docker" "$NAME" start --build
    assert_success
    run cat "$MVN_LOG"
    assert_output "$DISTRO clean package -U"
    run docker run --rm "$IMAGE:latest" cat /marker
    assert_output built
    run docker inspect -f '{{.Config.Image}}' "$NAME-openmrs"
    assert_output "$IMAGE:latest"
}

@test "a build command that would be refused is refused before Maven runs" {
    run "$BIN/openmrs-docker" "$NAME" start --build --bogus
    assert_failure
    assert_output --partial "unknown option '--bogus' for start"
    # held by another command
    ( exec 9>>"$PIHX_HOME/$NAME/.lock"; flock 9; echo "initialize (pid $BASHPID)" > "$PIHX_HOME/$NAME/.lock"; exec sleep 30 ) 3>&- &
    local holder=$!
    until grep -q initialize "$PIHX_HOME/$NAME/.lock" 2>/dev/null; do sleep 0.1; done
    run "$BIN/openmrs-docker" "$NAME" build
    kill "$holder"
    assert_failure
    assert_output --partial "$NAME is busy"
    [ ! -e "$MVN_LOG" ] || fail "Maven ran: $(cat "$MVN_LOG")"
}

@test "OPENMRS_DISTRO_DIR must be absolute" {
    local other
    other="$(instance other)"
    run env OPENMRS_DISTRO_DIR=distro "$BIN/openmrs-docker" "$other" create
    assert_failure
    assert_output --partial "OPENMRS_DISTRO_DIR must be an absolute path"
    [ ! -e "$PIHX_HOME/$other" ]
}

@test "SERVICE_NAME set when a command runs doesn't change the project or container names" {
    run env SERVICE_NAME="$NAME-other" "$BIN/openmrs-docker" "$NAME" start --build
    assert_success
    run docker ps -a --format '{{.Names}}' --filter "name=^$NAME-other"
    assert_output ''
    run docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$NAME-openmrs-db"
    assert_output "$NAME"
}
