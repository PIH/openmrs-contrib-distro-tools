#!/bin/sh
set -e
mkdir -p /target/data /target/db-init
# /target/data and /target/db-init are only real volume mounts when initialize's
# restore-*-volume-from-seed.yaml overlay for that axis is actually in play -- each mounts only
# the volume it's populating, so an axis restored from elsewhere (RESTORE_*_PATH) leaves its
# corresponding /target/* path as a plain, unmounted directory in this container's own throwaway
# layer. Skip extracting into it: nothing would ever read the result, and for openmrs-data in
# particular that's a potentially multi-GB tar extraction wasted for nothing.
if grep -q ' /target/data ' /proc/mounts; then
    tar xzf /seed/data.tar.gz -C /target/data
fi
if grep -q ' /target/db-init ' /proc/mounts; then
    cp /seed/dump.sql.gz /target/db-init/dump.sql.gz
fi
