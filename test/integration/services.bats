#!/usr/bin/env bats
# Attaching and removing fragments, run-service, and destroy, with small alpine fragments in place of the real services.

load ../helpers

setup() {
    NAME="$(instance)"
    SERVICES=openmrs-db create_instance "$NAME"
    DIR="$OPENMRS_DOCKER_HOME/$NAME"
    # Two small fragments instead of openmrs-db, so nothing heavy has to start.
    rm "$DIR/openmrs-db.yaml"
    for svc in keep gone; do
        cat > "$DIR/$svc.yaml" <<YAML
name: \${SERVICE_NAME:?SERVICE_NAME must be set}
services:
  $svc:
    container_name: \${SERVICE_NAME:?SERVICE_NAME must be set}-$svc
    image: alpine:3.21
    command: ["sleep", "300"]
    volumes:
      - $svc-data:/data
volumes:
  $svc-data:
YAML
    done
}
teardown() {
    destroy_instance "$NAME"
    common_teardown
}

running() { docker ps -q --filter "label=com.docker.compose.project=$NAME"; }

@test "remove-service on a stopped instance leaves it stopped" {
    "$BIN/openmrs-docker" "$NAME" start >/dev/null 2>&1
    "$BIN/openmrs-docker" "$NAME" stop >/dev/null 2>&1
    run "$BIN/openmrs-docker" "$NAME" remove-service gone
    assert_success
    assert_equal "$(running)" ""
    [ ! -e "$DIR/gone.yaml" ]
}

@test "remove-service on a running instance removes only that fragment's containers, and keeps its volumes" {
    "$BIN/openmrs-docker" "$NAME" start >/dev/null 2>&1
    local keep_id
    keep_id=$(docker ps -q --filter "name=^$NAME-keep$")
    run "$BIN/openmrs-docker" "$NAME" remove-service gone
    assert_success
    assert_output --partial "${NAME}_gone-data"
    assert_equal "$(docker ps -aq --filter "name=^$NAME-gone$")" ""
    assert_equal "$(docker ps -q --filter "name=^$NAME-keep$")" "$keep_id"
    run docker volume inspect "${NAME}_gone-data"
    assert_success
}

@test "remove-service refuses when what's left isn't valid Compose, and keeps the fragment" {
    cat > "$DIR/keep.yaml" <<'YAML'
name: ${SERVICE_NAME:?SERVICE_NAME must be set}
services:
  keep:
    image: alpine:3.21
    command: ["sleep", "300"]
    depends_on:
      - gone
YAML
    run "$BIN/openmrs-docker" "$NAME" remove-service gone
    assert_failure
    assert_output --partial "gone"
    [ -e "$DIR/gone.yaml" ]
}

@test "run-service runs a profiled fragment once with the given command, and start leaves it alone" {
    cat > "$DIR/job.yaml" <<'YAML'
name: ${SERVICE_NAME:?SERVICE_NAME must be set}
services:
  job:
    image: alpine:3.21
    profiles: ["job"]
YAML
    "$BIN/openmrs-docker" "$NAME" start >/dev/null 2>&1
    assert_equal "$(running | wc -l)" 2
    run "$BIN/openmrs-docker" "$NAME" run-service job echo "hello from job"
    assert_success
    assert_output --partial 'hello from job'
    assert_equal "$(docker ps -aq --filter "label=com.docker.compose.service=job" --filter "label=com.docker.compose.project=$NAME")" ""
    run "$BIN/openmrs-docker" "$NAME" run-service nope
    assert_failure
    assert_output --partial "nope not present on $NAME"
}

@test "destroy removes everything even when the fragments no longer interpolate" {
    "$BIN/openmrs-docker" "$NAME" start >/dev/null 2>&1
    assert_equal "$(running | wc -l)" 2
    sed -i 's/image: alpine:3.21/image: alpine:${NOT_SET_ANYWHERE?}/' "$DIR/keep.yaml"
    run "$BIN/openmrs-docker" "$NAME" destroy --force
    assert_success
    assert_output --partial "removing this instance's containers and volumes by their Compose project label"
    assert_equal "$(docker ps -aq --filter "label=com.docker.compose.project=$NAME")" ""
    assert_equal "$(docker volume ls -q --filter "label=com.docker.compose.project=$NAME")" ""
    [ ! -e "$DIR" ]
}

@test "destroy removes root-owned files a container left in the instance directory" {
    docker run --rm -v "$DIR:/d" alpine:3.21 sh -c 'mkdir /d/out && touch /d/out/report && chmod 700 /d/out'
    run "$BIN/openmrs-docker" "$NAME" destroy --force
    assert_success
    [ ! -e "$DIR" ]
}
