# `initialize` for a DHIS2 instance (instance_kind dhis2): fills dhis2-db-data from a pg_dump and,
# optionally, dhis2-data from a DHIS2 home, before the first start. Restores run in containers of the
# overlays in docker/modes/. Shares require_new_instance, overlay and archive_name_for with
# initialize.sh. Sourced by openmrs-docker.

initialize_dhis2() {
    require_new_instance
    export P7ZIP_IMAGE
    select_pgdump_source
    select_dhis2_data_source
    check_dhis2_restore_space
    if ! compose up -d dhis2-db || ! "$TOOL_DIR/utils/wait-for-healthy.sh" --container="${SERVICE_NAME}-dhis2-db" \
            --timeout="${INITIALIZE_DB_TIMEOUT:-3600}"; then
        compose logs --tail=20 dhis2-db >&2 || true
        dhis2_restore_failed
    fi
    compose down
    remove_restore_volumes "$SERVICE_NAME"
    echo "Initialized $NAME."
}

# dhis2-db-data: RESTORE_PGDUMP_PATH, required (there's no DHIS2 seed image).
select_pgdump_source() {
    [ -n "${RESTORE_PGDUMP_PATH:-}" ] || die "set RESTORE_PGDUMP_PATH to a pg_dump (.sql, .sql.gz, or a .7z/.zip of one) to initialize a DHIS2 instance's dhis2-db-data volume"
    [ -f "$RESTORE_PGDUMP_PATH" ] || die "no such file: $RESTORE_PGDUMP_PATH"
    RESTORE_PGDUMP_PATH=$(abs_path "$RESTORE_PGDUMP_PATH")
    export RESTORE_PGDUMP_PATH
    case "$RESTORE_PGDUMP_PATH" in
        *.7z|*.zip)
            RESTORE_PGDUMP_ARCHIVE_FILENAME=$(archive_name_for "$RESTORE_PGDUMP_PATH" 7z zip)
            export RESTORE_PGDUMP_ARCHIVE_FILENAME
            overlay restore-dhis2-db-volume-from-dump-archive
            ;;
        *.gz) export RESTORE_PGDUMP_FILENAME=dump.sql.gz; overlay restore-dhis2-db-volume-from-dump ;;
        *) export RESTORE_PGDUMP_FILENAME=dump.sql; overlay restore-dhis2-db-volume-from-dump ;;
    esac
}

# dhis2-data: RESTORE_DHIS2_DATA_PATH, or else empty (DHIS2 starts without its uploaded files and
# installed apps).
select_dhis2_data_source() {
    local name
    [ -n "${RESTORE_DHIS2_DATA_PATH:-}" ] || return 0
    [ -e "$RESTORE_DHIS2_DATA_PATH" ] || die "no such file or directory: $RESTORE_DHIS2_DATA_PATH"
    RESTORE_DHIS2_DATA_PATH=$(abs_path "$RESTORE_DHIS2_DATA_PATH")
    export RESTORE_DHIS2_DATA_PATH
    if [ -d "$RESTORE_DHIS2_DATA_PATH" ]; then
        overlay restore-dhis2-data-volume-from-backup
    else
        name=$(archive_name_for "$RESTORE_DHIS2_DATA_PATH" tar.gz tgz tar 7z zip)
        [ -n "$name" ] || die "RESTORE_DHIS2_DATA_PATH must be a directory or a .tar.gz/.tgz/.tar/.7z/.zip archive: $RESTORE_DHIS2_DATA_PATH"
        export RESTORE_DHIS2_DATA_ARCHIVE_FILENAME=$name
        overlay restore-dhis2-data-volume-from-archive
    fi
}

# As check_restore_space: refuses, before any volume exists, if there's clearly not room.
check_dhis2_restore_space() {
    local kb
    kb=$(disk_space_contents_size "$RESTORE_PGDUMP_PATH")
    # An archive is extracted into a temporary volume first, then imported.
    case "$RESTORE_PGDUMP_PATH" in *.7z|*.zip) kb=$((kb * 2)) ;; esac
    if [ -d "${RESTORE_DHIS2_DATA_PATH:-}" ]; then
        kb=$((kb + $(disk_space_size_of "$RESTORE_DHIS2_DATA_PATH")))
    elif [ -n "${RESTORE_DHIS2_DATA_PATH:-}" ]; then
        kb=$((kb + $(disk_space_contents_size "$RESTORE_DHIS2_DATA_PATH")))
    fi
    disk_space_require "restoring into $NAME's volumes (a dump import usually needs more than the dump itself)" \
        "$kb" "$(disk_space_free_on_docker_volumes)" "Docker's volumes"
}

# The volumes were all made by this run (require_new_instance), so a failed restore leaves none.
dhis2_restore_failed() {
    local vol
    compose down || true
    remove_restore_volumes "$SERVICE_NAME"
    for vol in $(compose config --volumes); do
        docker volume rm "${SERVICE_NAME}_${vol}" >/dev/null 2>&1 || true
    done
    die "initialize failed, and removed the volumes it made. A dump restores only into an empty database, so it must not drop or clean first: take one with 'openmrs-utils backup-pgdump', or pg_dump -O -x without -c. Then run initialize again."
}
