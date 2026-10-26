# `backup`: the instance's database and data directory, into --output-dir, as files `initialize`
# restores from. Sourced by openmrs-docker.

cmd_backup() { # --output-dir=<dir>
    local dir=${1#--output-dir=}
    if [ "$(instance_kind)" != dhis2 ]; then
        die "backup isn't implemented for OpenMRS instances yet (see TASKS-597); use openmrs-utils backup-mysqldump and backup-openmrs-data-directory"
    fi
    backup_dhis2 "$dir"
}

# <dir>/<instance>_<stamp>.sql.7z (RESTORE_PGDUMP_PATH) and <dir>/<instance>_data_<stamp>.7z
# (RESTORE_DHIS2_DATA_PATH), both encrypted with ARCHIVE_PASSWORD. Taken with DHIS2 running.
backup_dhis2() { # <dir>
    local dir=$1 stamp
    [ -n "${ARCHIVE_PASSWORD:-}" ] || die "ARCHIVE_PASSWORD must be set: backups are encrypted"
    stamp=$(date +%Y%m%d-%H%M%S)
    mkdir -p "$dir"
    "$TOOL_DIR/utils/backup-pgdump.sh" --container="${SERVICE_NAME}-dhis2-db" \
        --output="$dir/${SERVICE_NAME}_${stamp}.sql.7z" --database="$DHIS2_DB_NAME" --user="$DHIS2_DB_USER"
    "$TOOL_DIR/utils/backup-openmrs-data-directory.sh" --volume="${SERVICE_NAME}_dhis2-data" \
        --output="$dir/${SERVICE_NAME}_data_${stamp}.7z" --allow-running
    echo "Backed up $NAME to $dir."
}
