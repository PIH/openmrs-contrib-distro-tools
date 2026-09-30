# Commands that create, change and remove an instance's directory. Sourced by openmrs-docker.

cmd_create() { # <name>
    local name=$1 dir="$OPENMRS_DOCKER_HOME/$1" svc var env_content services needs_openmrs=false
    valid_name "$name" || die "instance name '$name' $NAME_RULE (it's the Compose project name)"
    [ ! -e "$dir" ] || die "instance directory already exists: $dir"
    IFS=',' read -ra services <<< "${SERVICES:-openmrs-db,openmrs}"
    for svc in "${services[@]}"; do
        [ -f "$SERVICES_DIR/$svc.yaml" ] || die "no such service '$svc' (looked for $SERVICES_DIR/$svc.yaml)"
        [ "$svc" != openmrs ] || needs_openmrs=true
    done
    if $needs_openmrs && [ -z "${OPENMRS_IMAGE_NAME:-}" ]; then
        die "OPENMRS_IMAGE_NAME must be set to create an instance that includes the 'openmrs' service"
    fi
    # Each value comes from the calling shell's environment if set there. Rendered before anything
    # is created, so a value env_line refuses leaves no half-created instance behind.
    env_content=$(
        echo "# instance"
        env_line TZ "${TZ:-UTC}"
        env_line SERVICE_NAME "$name"
        env_line DISTRO_SOURCE_DIR "${DISTRO_SOURCE_DIR:-}"
        echo "# seed"
        env_line SEED_IMAGE_NAME "${SEED_IMAGE_NAME:-}"
        env_line SEED_IMAGE_TAG "${SEED_IMAGE_TAG:-latest}"
        for svc in "${services[@]}"; do
            render_service_env_defaults "$svc"
        done
        # openmrs-core's startup-init.sh turns any OMRS_EXTRA_* into a runtime property.
        for var in "${!OMRS_EXTRA_@}"; do
            env_line "$var" "${!var}"
        done
        # Server options (see openmrs-db.yaml) that openmrs-db.env.defaults doesn't already write.
        for var in "${!OPENMRS_DB_OPT_@}"; do
            [ -n "${ENV_LINES_WRITTEN[$var]:-}" ] || env_line "$var" "${!var}"
        done
    ) || exit 1
    mkdir -p "$dir"
    printf '%s\n' "$env_content" > "$dir/env"
    for svc in "${services[@]}"; do
        cp "$SERVICES_DIR/$svc.yaml" "$dir/$svc.yaml"
    done
    write_container_env_files "$dir"
    echo "Created instance '$name' at $dir"
}

cmd_list() {
    local d
    # Only directories with an env file: openmrs-sdk servers share the default ~/openmrs.
    for d in "$OPENMRS_DOCKER_HOME"/*/; do
        [ -f "$d/env" ] && basename "$d"
    done
    return 0
}

# Refreshes each fragment from its canonical file, and adds to env, with its default, any variable
# the refreshed fragments require that env doesn't have yet.
cmd_sync() {
    local f svc canonical defaults rendered=() i=0 added
    # Rendered first: a value env_line refuses stops here, before anything is changed.
    for f in "$INSTANCE_DIR"/*.yaml; do
        [ -e "$f" ] || continue
        defaults=$(render_service_env_defaults "$(basename "$f" .yaml)") || exit 1
        rendered+=("$defaults")
    done
    for f in "$INSTANCE_DIR"/*.yaml; do
        [ -e "$f" ] || continue
        svc=$(basename "$f" .yaml)
        canonical="$SERVICES_DIR/$svc.yaml"
        if [ -e "$canonical" ]; then
            cp "$canonical" "$f"
            echo "Synced $svc.yaml"
            added=$(append_missing_env_defaults "${rendered[$i]}" --required)
            [ -z "$added" ] || echo "Added to env: $(paste -sd' ' <<< "$added")"
        else
            echo "Skipped $svc.yaml (no canonical service found at $canonical)"
        fi
        i=$((i + 1))
    done
    write_container_env_files "$INSTANCE_DIR"
}

cmd_add_service() { # <svc>
    local svc=$1 dest="$INSTANCE_DIR/$1.yaml" defaults
    [ ! -e "$dest" ] || die "$svc already present on $NAME"
    [ -e "$SERVICES_DIR/$svc.yaml" ] || die "no such service '$svc'"
    # Rendered first: a value env_line refuses stops here, before anything is changed.
    defaults=$(render_service_env_defaults "$svc") || exit 1
    cp "$ENV_FILE" "$INSTANCE_DIR/.env.before-add-service"
    cp "$SERVICES_DIR/$svc.yaml" "$dest"
    append_missing_env_defaults "$defaults" --all >/dev/null
    write_container_env_files "$INSTANCE_DIR"
    compose_files
    # e.g. a mediator added without the openhim it depends on: every later command would fail.
    if ! compose --profile '*' config -q; then
        rm "$dest"
        mv "$INSTANCE_DIR/.env.before-add-service" "$ENV_FILE"
        write_container_env_files "$INSTANCE_DIR"
        die "adding $svc leaves $NAME's services invalid (above) -- nothing changed."
    fi
    rm "$INSTANCE_DIR/.env.before-add-service"
    if grep -q '^\s*profiles:' "$dest"; then
        echo "Added $svc (profiled -- 'start' won't bring it up). Run '$0 $NAME run-service $svc [cmd...]' to invoke it."
    else
        echo "Added $svc. Run '$0 $NAME start' to bring it up."
    fi
}

cmd_remove_service() { # <svc>
    local svc=$1 target="$INSTANCE_DIR/$1.yaml" kept_services kept_volumes left_volumes
    [ -e "$target" ] || die "$svc not present on $NAME"
    mv "$target" "$INSTANCE_DIR/.$svc.yaml.removed"
    compose_files
    # All profiles, so a profiled service's containers (e.g. a running smoke test) count as kept.
    if ! kept_services=$(compose --profile '*' config --services); then
        mv "$INSTANCE_DIR/.$svc.yaml.removed" "$target"
        die "removing $svc leaves $NAME's services invalid (above) -- nothing changed."
    fi
    kept_volumes=$(compose --profile '*' config --volumes)
    rm "$INSTANCE_DIR/.$svc.yaml.removed"
    rm -f "$INSTANCE_DIR/$svc.env"
    # Only the containers of services no fragment declares any more: `up --remove-orphans` would
    # also start everything else.
    docker ps -a --filter "label=com.docker.compose.project=$SERVICE_NAME" \
            --format '{{.ID}} {{.Label "com.docker.compose.service"}}' | while read -r id s; do
        grep -qxF "$s" <<< "$kept_services" || docker rm -f "$id" >/dev/null
    done
    left_volumes=$(docker volume ls --filter "label=com.docker.compose.project=$SERVICE_NAME" \
            --format '{{.Name}} {{.Label "com.docker.compose.volume"}}' | while read -r vol key; do
        grep -qxF "$key" <<< "$kept_volumes" || echo "$vol"
    done)
    echo "Removed $svc."
    [ -z "$left_volumes" ] || echo "Its volumes are left in place (docker volume rm them if they're no longer needed): $(paste -sd' ' <<< "$left_volumes")"
}

cmd_destroy() {
    # Compose's own project name, for an instance created before names were checked.
    local project="${SERVICE_NAME,,}" confirm
    if ! $FORCE; then
        echo "This will stop the stack, delete all volumes, and remove $INSTANCE_DIR."
        read -r -p "Are you sure? [y/N] " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || exit 0
    fi
    # An instance whose fragments don't interpolate (e.g. a required variable unset) must still be
    # destroyable, so its containers and volumes are then found by Compose's project label.
    if ! compose down -v --remove-orphans; then
        warn "'docker compose down' failed -- removing this instance's containers and volumes by their Compose project label instead."
        docker ps -aq --filter "label=com.docker.compose.project=$project" | xargs -r docker rm -f >/dev/null 2>&1 || true
        docker volume ls -q --filter "label=com.docker.compose.project=$project" | xargs -r docker volume rm >/dev/null 2>&1 || true
    fi
    remove_restore_volumes "$project"
    if ! rm -rf "$INSTANCE_DIR" 2>/dev/null; then
        # A one-off service (e.g. smoke tests via run-service) may have written root-owned files
        # into a bind-mounted directory under the instance's.
        docker run --rm -v "$INSTANCE_DIR:/target" "$ALPINE_IMAGE" chown -R "$(id -u):$(id -g)" /target
        rm -rf "$INSTANCE_DIR"
    fi
    echo "Removed instance directory $INSTANCE_DIR"
}
