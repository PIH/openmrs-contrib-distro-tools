# Commands for an instance's openmrs-db. Sourced by openmrs-docker.

require_db_data() { # <what the command does>
    [ -f "$INSTANCE_DIR/openmrs-db.yaml" ] || die "$NAME has no openmrs-db service"
    docker volume inspect "${SERVICE_NAME}_db-data" >/dev/null 2>&1 \
        || die "${SERVICE_NAME}_db-data doesn't exist -- nothing to $1"
}

# Sets the MySQL accounts and OpenMRS's connection settings to the passwords now in env (e.g. after
# rotating them). Changing env alone changes neither: MySQL takes MYSQL_ROOT_PASSWORD/MYSQL_PASSWORD
# only when it sets up an empty data directory, and openmrs-core 2.6+ applies
# OMRS_CONFIG_CONNECTION_* only on its first install. Done with the instance stopped.
cmd_reset_openmrs_db_accounts() {
    require_db_data reset
    compose down --remove-orphans
    MYSQL_ROOT_PASSWORD="$OPENMRS_DB_ROOT_PASSWORD" MYSQL_PASSWORD="$OPENMRS_DB_PASSWORD" \
        "$TOOL_DIR/utils/reset-mysql-accounts.sh" --volume="${SERVICE_NAME}_db-data" \
        --image="$OPENMRS_DB_IMAGE_NAME:$OPENMRS_DB_IMAGE_TAG" --user="$OPENMRS_DB_USER"
    if docker volume inspect "${SERVICE_NAME}_openmrs-data" >/dev/null 2>&1; then
        printf 'connection.username=%s\nconnection.password=%s\n' "$OPENMRS_DB_USER" "$OPENMRS_DB_PASSWORD" |
            "$TOOL_DIR/utils/runtime-properties.sh" --volume="${SERVICE_NAME}_openmrs-data" --set
    fi
    start_stack
}

# Fingerprints the stopped instance's db-data with its own image and server options (as
# openmrs-db.yaml turns OPENMRS_DB_OPT_* into flags), so it reads as the running instance does.
cmd_fingerprint() { # [--data-dir] [--exclude-distribution-artifacts] [--output=<file>]
    local args=(--db-volume="${SERVICE_NAME}_db-data" --image="$OPENMRS_DB_IMAGE_NAME:$OPENMRS_DB_IMAGE_TAG" --database=openmrs)
    local var opt arg
    for var in "${!OPENMRS_DB_OPT_@}"; do
        opt="${var#OPENMRS_DB_OPT_}"
        opt="${opt//_/-}"
        if [ -n "${!var}" ]; then args+=(--server-opt="--$opt=${!var}"); else args+=(--server-opt="--$opt"); fi
    done
    for arg in "$@"; do
        case "$arg" in
            --data-dir) args+=(--data-dir="${SERVICE_NAME}_openmrs-data") ;;
            --exclude-distribution-artifacts|--output=*) args+=("$arg") ;;
            *) die "unknown option '$arg' for fingerprint" ;;
        esac
    done
    require_db_data fingerprint
    "$TOOL_DIR/utils/fingerprint.sh" "${args[@]}"
}
