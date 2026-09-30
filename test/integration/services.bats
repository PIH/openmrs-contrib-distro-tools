#!/usr/bin/env bats
# remove-service removes only the containers of the fragment it removes, and never starts anything.

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
