#!/bin/bash
# openmrs's backup, run by the backups service (its with-backups.yaml mounts it): /sources/openmrs-data
# into openmrs.7z, holding one directory, openmrs/, as backup-openmrs-data-directory makes: leaving
# out the distribution artifacts (what the OpenMRS image copies in on every start) and each path in
# OPENMRS_DATA_BACKUP_EXCLUDES (space-separated, relative to the volume). Refuses links that point
# outside the volume. The volume is also mounted at /sources/openmrs, so the archive's directory has
# that name. Needs BACKUP_RUN_DIR and ARCHIVE_PASSWORD.
set -euo pipefail
: "${BACKUP_RUN_DIR:?}" "${ARCHIVE_PASSWORD:?}"
SRC=/sources/openmrs-data
TOP=openmrs

# What the image rebuilds: the four directories' contents (the directories are kept, empty) and the lib cache.
LEAVE_OUT=(modules owa configuration frontend .openmrs-lib-cache)
EXCLUDES=("-x!$TOP/modules/*" "-x!$TOP/owa/*" "-x!$TOP/configuration/*" "-x!$TOP/frontend/*" "-x!$TOP/.openmrs-lib-cache")
set -f   # a * in an exclude isn't expanded here
for path in ${OPENMRS_DATA_BACKUP_EXCLUDES:-}; do
    while [ "${path%/}" != "$path" ]; do path=${path%/}; done
    case "/$path/" in
        //|/./|/\/*) echo "error: OPENMRS_DATA_BACKUP_EXCLUDES needs paths relative to the volume: $path" >&2; exit 1 ;;
        */../*|*/./*) echo "error: OPENMRS_DATA_BACKUP_EXCLUDES paths can't hold . or .. : $path" >&2; exit 1 ;;
    esac
    LEAVE_OUT+=("$path")
    EXCLUDES+=("-x!$TOP/$path")
done
set +f

LINKS=$(sh /opt/backup/in-container/outside-links.sh "$SRC" "${LEAVE_OUT[@]}")
if [ -n "$LINKS" ]; then
    echo "error: symbolic links pointing outside openmrs-data, which a backup can't carry over (delete the ones not needed, leave them out with OPENMRS_DATA_BACKUP_EXCLUDES, or replace them with what they point to):
$LINKS" >&2
    exit 1
fi

echo "openmrs: archiving $SRC" >&2
cd /sources
# Links are stored as links (-snl); the password on stdin, so it isn't on 7z's command line.
printf '%s\n' "$ARCHIVE_PASSWORD" | 7z a -p -mx5 -mmt2 -t7z -snl "$BACKUP_RUN_DIR/openmrs.7z" "$TOP" "${EXCLUDES[@]}" >/dev/null
