#!/bin/sh
# Runs in a restore container once openmrs-data (/target) is filled (restore/*.yaml):
# - moves a restored openmrs-runtime.properties aside to openmrs-runtime.properties.restored: it
#   holds the source server's settings and secrets (openmrs-core 2.8.11+ overrides only the connection
#   settings and OMRS_EXTRA_* in an existing file), so OpenMRS writes a fresh one on first start
# - gives everything to OWNER (<uid>:<gid>, the openmrs image's runtime user unless OPENMRS_DATA_OWNER
#   is set): restored files keep the source host's owners, which that user can't write to
set -e
f=/target/openmrs-runtime.properties
if [ -f "$f" ]; then
    mv "$f" "$f.restored"
    echo "Moved openmrs-runtime.properties aside to openmrs-runtime.properties.restored -- OpenMRS will write a fresh one from the instance's env on its first start."
fi
chown -R "$OWNER" /target
echo "Changed the owner of the restored openmrs-data to $OWNER."
