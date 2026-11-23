#!/bin/bash
# initialize, sqlserver.7z (as its backup writes, docs/backups.md): restores each <db>.bak in it as the
# database <db> into the new server, once it's healthy (restore/archive.yaml runs this in the
# backup-tools image). sqlserver-data is mounted here at /var/opt/mssql, where the server has it, so
# a .bak extracted there is a path the server can read; the database's files go to its data
# directory, /var/opt/mssql/data. The logins come on the first start: sqlserver-setup creates the
# declared ones and remaps the restored user named after each to it, in that login's databases.
# Needs ARCHIVE_PASSWORD (if the archive has one), SQLCMDPASSWORD (sa's) and ENTRY (the archive's
# name under /source).
set -euo pipefail
: "${SQLCMDPASSWORD:?}" "${ENTRY:?}"
STAGING=/var/opt/mssql/.restore-staging
cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT

sh /extract.sh "/source/$ENTRY" "$STAGING"
# The server runs as mssql (uid 10001 in Microsoft's image), which owns its data directory.
chown -R "$(stat -c %u:%g /var/opt/mssql/data)" "$STAGING"
mapfile -t baks < <(find "$STAGING" -maxdepth 1 -type f -name '*.bak' | sort)
if [ ${#baks[@]} -eq 0 ]; then
    echo "error: $ENTRY holds no <database>.bak" >&2
    exit 1
fi

q() { sqlcmd -S sqlserver -U sa -C -b -h -1 -W -s '|' -Q "SET NOCOUNT ON; $1"; }
for bak in "${baks[@]}"; do
    db=$(basename "$bak" .bak)
    if [[ ! "$db" =~ ^[A-Za-z0-9_]+$ ]]; then
        echo "error: $(basename "$bak"): not a database name (letters, digits and _)" >&2
        exit 1
    fi
    echo "sqlserver: restoring $db" >&2
    # Each of the backup's files moved into this server's data directory, named after the database
    # and the file's id (unique within the database, where logical names may differ only in
    # punctuation): data (D) as .mdf for the primary file and .ndf for others, the log (L) as .ldf,
    # and a FILESTREAM or memory-optimized container (S) or full-text catalog (F), which is a
    # directory, with no extension. FILELISTONLY's columns: LogicalName, PhysicalName, Type,
    # FileGroupName, Size, MaxSize, FileId, ...
    moves=()
    while IFS='|' read -r logical _physical type _group _size _max file_id _rest; do
        [ -n "$logical" ] || continue
        if [[ ! "$file_id" =~ ^[0-9]+$ ]]; then
            echo "error: couldn't read the files of $(basename "$bak")" >&2
            exit 1
        fi
        target="/var/opt/mssql/data/${db}_${file_id}"
        case "$type" in
            D) if [ "$file_id" = 1 ]; then target+=.mdf; else target+=.ndf; fi ;;
            L) target+=.ldf ;;
        esac
        moves+=("MOVE N'${logical//\'/\'\'}' TO N'$target'")
    done < <(q "RESTORE FILELISTONLY FROM DISK = N'$bak'")
    if [ ${#moves[@]} -eq 0 ]; then
        echo "error: couldn't read the files of $(basename "$bak")" >&2
        exit 1
    fi
    q "RESTORE DATABASE [$db] FROM DISK = N'$bak' WITH $(IFS=,; echo "${moves[*]}"), RECOVERY, CHECKSUM" >&2
done
