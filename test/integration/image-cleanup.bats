#!/usr/bin/env bats
# start and update remove the images their recreated containers no longer use: one a pull of the same
# tag replaced, or one a registry has. Never a local build still tagged, nor an image another
# container uses.

load ../helpers

setup_file() {
    export REGISTRY_CONTAINER
    REGISTRY_CONTAINER="$(file_res registry)"
    start_registry "$REGISTRY_CONTAINER"
}
teardown_file() {
    docker rm -f "$REGISTRY_CONTAINER" >/dev/null 2>&1 || true
    common_teardown_file
}

# The instance's one service: modality-simulator, whose image each test chooses (start_on).
setup() {
    NAME="$(instance)"
    MODALITY_SIMULATOR_IMAGE_NAME=alpine MODALITY_SIMULATOR_IMAGE_TAG=3.21 \
        MODALITY_SIMULATOR_GATEWAY_AE=GW MODALITY_SIMULATOR_HOST_PORT=0 MODALITY_SIMULATOR_IMAGE_DIR=/tmp \
        create_instance "$NAME" --services=modality-simulator 2>/dev/null
}
teardown() {
    destroy_instance "$NAME"
    remove_images "$NAME-"
    remove_images "$REGISTRY/$NAME-"
    common_teardown
}

# Points the instance's service at <ref> and starts it (through openmrs-docker).
start_on() { # <ref>
    set_env_value "$NAME" modality-simulator MODALITY_SIMULATOR_IMAGE_NAME "${1%:*}"
    set_env_value "$NAME" modality-simulator MODALITY_SIMULATOR_IMAGE_TAG "${1##*:}"
    run "$BIN/openmrs-docker" "$NAME" start
    assert_success
}

@test "a new tag: the image it replaced is removed, if a registry has it" {
    local old="$REGISTRY/$NAME-app:1" new="$REGISTRY/$NAME-app:2" old_id
    build_test_image "$old" "$NAME-one" && docker push -q "$old" >/dev/null
    build_test_image "$new" "$NAME-two" && docker push -q "$new" >/dev/null
    start_on "$old"
    old_id=$(image_id "$old")
    start_on "$new"
    assert_output --partial "Removed the replaced image ${old_id#sha256:}"
    [ -z "$(image_id "$old")" ] || fail "$old is still there"
    [ -n "$(image_id "$new")" ] || fail "$new, in use, was removed"
}

@test "a new image under the same tag: the one it replaced, untagged, is removed" {
    local ref="$NAME-same:latest" old_id
    build_test_image "$ref" "$NAME-one"
    start_on "$ref"
    old_id=$(image_id "$ref")
    build_test_image "$ref" "$NAME-two"
    start_on "$ref"
    run docker image inspect "$old_id"
    assert_failure
}

@test "a local build still tagged, which no registry has, is kept" {
    local local_ref="$NAME-local:1" new="$REGISTRY/$NAME-app:2"
    build_test_image "$local_ref" "$NAME-local"
    build_test_image "$new" "$NAME-two" && docker push -q "$new" >/dev/null
    start_on "$local_ref"
    start_on "$new"
    [ -n "$(image_id "$local_ref")" ] || fail "$local_ref, a local build, was removed"
}

@test "an image another container is made from is kept" {
    local old="$REGISTRY/$NAME-app:1" new="$REGISTRY/$NAME-app:2"
    build_test_image "$old" "$NAME-one" && docker push -q "$old" >/dev/null
    build_test_image "$new" "$NAME-two" && docker push -q "$new" >/dev/null
    docker run -d --name "$NAME-other" "$old" >/dev/null
    start_on "$old"
    start_on "$new"
    [ -n "$(image_id "$old")" ] || fail "$old, in use by $NAME-other, was removed"
}
