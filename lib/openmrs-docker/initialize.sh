# `initialize`: fills a brand-new instance's volumes before its first start, each from its own
# source (see the usage text), so e.g. db-data can come from a dump while openmrs-data comes from
# SEED_IMAGE_NAME. Restores run in containers of the overlays in docker/modes/, never on the host.
# Sourced by openmrs-docker.

cmd_initialize() {
    require_new_instance
    # For the overlays: the images they run (openmrs-docker exports the utils dir they mount from).
    export P7ZIP_IMAGE PERCONA_IMAGE
    select_db_source
    select_data_source
    check_restore_space
    resolve_data_owner
    run_restore
    # The volumes are filled from here on, so a failure leaves the instance half-initialized.
    on_failure 'echo "error: initialize failed -- run '"'$0 $NAME destroy'"' before retrying." >&2'
    finish_restore
    echo "Initialized $NAME."
}

overlay() { COMPOSE_FILES+=(-f "$MODES_DIR/$1.yaml"); }

# The name an overlay mounts an archive as, archive.<ext>, so it picks the right extractor. Empty if
# <path> doesn't end in one of the extensions.
archive_name_for() { # <path> <extension...>
    local path=$1 ext
    shift
    for ext in "$@"; do
        case "$path" in *."$ext") [ "$ext" != tgz ] || ext=tar.gz; echo "archive.$ext"; return ;; esac
    done
}

require_new_instance() {
    local volumes vol
    # Assigned first: set -e doesn't fire on a failed $(...) in a for loop's word list, and this is
    # initialize's only protection against clobbering existing data.
    volumes=$(compose config --volumes)
    for vol in $volumes; do
        if docker volume inspect "${SERVICE_NAME}_${vol}" >/dev/null 2>&1; then
            die "${SERVICE_NAME}_${vol} already exists -- initialize only runs against a brand-new instance with no existing data. Run '$0 $NAME destroy' first if you really want to start over."
        fi
    done
}

# db-data: exactly one of RESTORE_MYSQL_DUMP_PATH, RESTORE_MYSQL_DATA_PATH or
# RESTORE_MYSQL_PERCONA_PATH, or else SEED_IMAGE_NAME. A physical restore (data directory or
# Percona) brings the source's accounts, which reset-mysql-accounts.yaml then sets to this instance's.
select_db_source() {
    local sources=0
    DB_PHYSICAL_RESTORE=false
    if [ -n "${RESTORE_MYSQL_DUMP_PATH:-}" ]; then
        [ -f "$RESTORE_MYSQL_DUMP_PATH" ] || die "no such file: $RESTORE_MYSQL_DUMP_PATH"
        RESTORE_MYSQL_DUMP_PATH=$(abs_path "$RESTORE_MYSQL_DUMP_PATH")
        export RESTORE_MYSQL_DUMP_PATH
        case "$RESTORE_MYSQL_DUMP_PATH" in
            *.7z|*.zip)
                RESTORE_MYSQL_DUMP_ARCHIVE_FILENAME=$(archive_name_for "$RESTORE_MYSQL_DUMP_PATH" 7z zip)
                export RESTORE_MYSQL_DUMP_ARCHIVE_FILENAME
                overlay restore-mysql-volume-from-dump-archive
                ;;
            *.gz) export RESTORE_MYSQL_DUMP_FILENAME=dump.sql.gz; overlay restore-mysql-volume-from-dump ;;
            *) export RESTORE_MYSQL_DUMP_FILENAME=dump.sql; overlay restore-mysql-volume-from-dump ;;
        esac
        sources=$((sources + 1))
    fi
    if [ -n "${RESTORE_MYSQL_DATA_PATH:-}" ]; then
        [ -d "$RESTORE_MYSQL_DATA_PATH" ] || die "no such directory: $RESTORE_MYSQL_DATA_PATH"
        RESTORE_MYSQL_DATA_PATH=$(abs_path "$RESTORE_MYSQL_DATA_PATH")
        export RESTORE_MYSQL_DATA_PATH
        overlay restore-mysql-volume-from-data-dir
        sources=$((sources + 1))
        DB_PHYSICAL_RESTORE=true
    fi
    if [ -n "${RESTORE_MYSQL_PERCONA_PATH:-}" ]; then
        [ -e "$RESTORE_MYSQL_PERCONA_PATH" ] || die "no such file or directory: $RESTORE_MYSQL_PERCONA_PATH"
        RESTORE_MYSQL_PERCONA_PATH=$(abs_path "$RESTORE_MYSQL_PERCONA_PATH")
        RESTORE_MYSQL_PERCONA_NAME=backup
        if [ -f "$RESTORE_MYSQL_PERCONA_PATH" ]; then
            RESTORE_MYSQL_PERCONA_NAME=$(archive_name_for "$RESTORE_MYSQL_PERCONA_PATH" 7z zip tar.gz tgz tar)
            [ -n "$RESTORE_MYSQL_PERCONA_NAME" ] || die "RESTORE_MYSQL_PERCONA_PATH must be a directory or a .7z/.zip/.tar.gz/.tgz/.tar archive: $RESTORE_MYSQL_PERCONA_PATH"
        fi
        export RESTORE_MYSQL_PERCONA_PATH RESTORE_MYSQL_PERCONA_NAME
        overlay restore-mysql-volume-from-percona
        sources=$((sources + 1))
        DB_PHYSICAL_RESTORE=true
    fi
    if $DB_PHYSICAL_RESTORE; then overlay reset-mysql-accounts; fi
    if [ "$sources" -eq 0 ] && [ -n "${SEED_IMAGE_NAME:-}" ]; then
        overlay restore-mysql-volume-from-seed
        sources=1
    fi
    [ "$sources" -eq 1 ] || die "set exactly one of RESTORE_MYSQL_DUMP_PATH, RESTORE_MYSQL_DATA_PATH, RESTORE_MYSQL_PERCONA_PATH, or SEED_IMAGE_NAME to initialize the mysql/db-data volume"
}

# openmrs-data: RESTORE_OPENMRS_DATA_PATH, or else SEED_IMAGE_NAME, or neither: then OpenMRS builds
# it up on its first start, as on a fresh install (e.g. for a database backup with no matching
# data directory backup). Sets DATA_SOURCE to restore, seed or none.
select_data_source() {
    local name
    DATA_SOURCE=none
    if [ -n "${RESTORE_OPENMRS_DATA_PATH:-}" ]; then
        [ -e "$RESTORE_OPENMRS_DATA_PATH" ] || die "no such file or directory: $RESTORE_OPENMRS_DATA_PATH"
        RESTORE_OPENMRS_DATA_PATH=$(abs_path "$RESTORE_OPENMRS_DATA_PATH")
        export RESTORE_OPENMRS_DATA_PATH
        if [ -d "$RESTORE_OPENMRS_DATA_PATH" ]; then
            overlay restore-openmrs-data-volume-from-backup
        else
            name=$(archive_name_for "$RESTORE_OPENMRS_DATA_PATH" tar.gz tgz tar 7z zip)
            [ -n "$name" ] || die "RESTORE_OPENMRS_DATA_PATH must be a directory or a .tar.gz/.tgz/.tar/.7z/.zip archive: $RESTORE_OPENMRS_DATA_PATH"
            export RESTORE_OPENMRS_DATA_ARCHIVE_FILENAME=$name
            overlay restore-openmrs-data-volume-from-archive
        fi
        DATA_SOURCE=restore
    elif [ -n "${SEED_IMAGE_NAME:-}" ]; then
        overlay restore-openmrs-data-volume-from-seed
        DATA_SOURCE=seed
    fi
}

# Refuses, before any volume exists, if Docker's volume filesystem clearly hasn't room
# (utils/lib/disk-space.sh). A seed image's size isn't known up front, so isn't counted.
check_restore_space() {
    local kb=0 what="restoring into $NAME's volumes"
    if [ -n "${RESTORE_MYSQL_DATA_PATH:-}" ]; then
        kb=$(disk_space_size_of "$RESTORE_MYSQL_DATA_PATH")
    elif [ -n "${RESTORE_MYSQL_PERCONA_PATH:-}" ]; then
        # Into percona-staging, then copied into db-data.
        if [ -d "$RESTORE_MYSQL_PERCONA_PATH" ]; then
            kb=$(disk_space_size_of "$RESTORE_MYSQL_PERCONA_PATH")
        else
            kb=$(disk_space_contents_size "$RESTORE_MYSQL_PERCONA_PATH")
        fi
        kb=$((kb * 2))
    elif [ -n "${RESTORE_MYSQL_DUMP_PATH:-}" ]; then
        kb=$(disk_space_contents_size "$RESTORE_MYSQL_DUMP_PATH")
        # An archive is extracted into a temporary volume first, then imported.
        case "$RESTORE_MYSQL_DUMP_PATH" in *.7z|*.zip) kb=$((kb * 2)) ;; esac
        what+=" (a dump import usually needs more than the dump itself)"
    fi
    if [ -d "${RESTORE_OPENMRS_DATA_PATH:-}" ]; then
        kb=$((kb + $(disk_space_size_of "$RESTORE_OPENMRS_DATA_PATH")))
    elif [ -n "${RESTORE_OPENMRS_DATA_PATH:-}" ]; then
        kb=$((kb + $(disk_space_contents_size "$RESTORE_OPENMRS_DATA_PATH")))
    fi
    [ "$kb" -eq 0 ] || disk_space_require "$what" "$kb" "$(disk_space_free_on_docker_volumes)" "Docker's volumes"
}

# A restored openmrs-data keeps the owners it had on the source host, which the openmrs image's
# non-root runtime user can't write to, so finish_restore gives it to that user. Found here, before
# any volume exists, so an image that can't be run fails first.
resolve_data_owner() {
    local image
    [ "$DATA_SOURCE" = restore ] && [ -z "${OPENMRS_DATA_OWNER:-}" ] || return 0
    image="${OPENMRS_IMAGE_NAME:?OPENMRS_IMAGE_NAME must be set}:${OPENMRS_IMAGE_TAG:-latest}"
    # shellcheck disable=SC2016
    OPENMRS_DATA_OWNER=$(docker run --rm --entrypoint sh "$image" -c 'echo "$(id -u):$(id -g)"') \
        || die "couldn't determine the runtime user of $image -- set OPENMRS_DATA_OWNER=<uid>:<gid> to choose the owner of the restored openmrs-data explicitly"
}

# Starts only openmrs-db, which pulls in the restore containers the overlays make it depend on. Its
# healthcheck is a real completion signal: MySQL accepts TCP connections only once the import (or a
# restored data directory's crash recovery) is done, and reports unhealthy until then.
run_restore() {
    if ! compose up -d openmrs-db; then
        # The failed container's output (e.g. 7z's "Wrong password") is the only clue, and `down`
        # removes the container.
        compose logs --tail=20 >&2 || true
        restore_failed
    fi
    # What the Percona restore and reset-mysql-accounts did, including the source's other accounts kept.
    [ -z "${RESTORE_MYSQL_PERCONA_PATH:-}" ] || docker logs "${SERVICE_NAME}-restore-mysql-volume" 2>&1 || true
    ! $DB_PHYSICAL_RESTORE || docker logs "${SERVICE_NAME}-reset-mysql-accounts" 2>&1 || true
    "$TOOL_DIR/utils/wait-for-healthy.sh" --container="${SERVICE_NAME}-openmrs-db" \
        --timeout="${INITIALIZE_DB_TIMEOUT:-3600}" || restore_failed
    compose down
    remove_restore_volumes "$SERVICE_NAME"
}

restore_failed() {
    compose down || true
    remove_restore_volumes "$SERVICE_NAME"
    die "initialize failed -- run '$0 $NAME destroy' before retrying."
}

finish_restore() {
    if [ "$DATA_SOURCE" = restore ]; then
        # It holds the source server's connection settings, which would win over this instance's
        # env (see utils/runtime-properties.sh). Kept, so custom properties can be carried over.
        "$TOOL_DIR/utils/runtime-properties.sh" --volume="${SERVICE_NAME}_openmrs-data" --set-aside
        docker run --rm -e OWNER="$OPENMRS_DATA_OWNER" -v "${SERVICE_NAME}_openmrs-data:/data" "$ALPINE_IMAGE" \
            sh -c 'chown -R "$OWNER" /data'
        echo "Changed the owner of the restored openmrs-data to $OPENMRS_DATA_OWNER."
    fi
    # db-data has a schema, but openmrs-data now has no runtime properties (none restored, or set
    # aside), so OpenMRS would take this for a new install and create every table again (see
    # openmrs.yaml). An OPENMRS_CREATE_TABLES already in env is kept.
    if [ "$DATA_SOURCE" != seed ] && ! grep -q '^OPENMRS_CREATE_TABLES=' "$ENV_FILE"; then
        env_line OPENMRS_CREATE_TABLES false >> "$ENV_FILE"
    fi
}
