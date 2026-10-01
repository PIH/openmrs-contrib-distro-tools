#!/bin/sh
# Fills the volumes initialize's seed overlays mount: /target/db-init gets the dump, /target/data
# the data directory. Each is a volume only when its overlay is in use (the other volume may come
# from a RESTORE_* path), so an unmounted one is skipped.
set -e
if grep -q ' /target/data ' /proc/mounts; then
    # data.tar.gz holds one data/ folder (backup-openmrs-data-directory); older seeds were flat.
    root=$(sh /extract.sh /seed/data.tar.gz /target/data/.seed-staging --print-root)
    find "$root" -mindepth 1 -maxdepth 1 -exec mv {} /target/data/ \;
    rm -rf /target/data/.seed-staging
fi
if grep -q ' /target/db-init ' /proc/mounts; then
    cp /seed/dump.sql.gz /target/db-init/dump.sql.gz
fi
