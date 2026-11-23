#!/bin/bash
# `pihx <instance> summary`: the [dhis2] section, the number of files under files/ and apps/ in the
# dhis2-data volume and the version marker (`none` before the first start), read from the volume
# whether DHIS2 runs or not. Counts only, no names. Run through pihx, which sets the environment
# (pihx/script.py).
set -euo pipefail
# shellcheck source=../../utils/lib/images.sh
. "$PIHX_TOOLS/utils/lib/images.sh"
volume="${SERVICE_NAME}_dhis2-data"
docker volume inspect "$volume" >/dev/null 2>&1 || {
    echo "error: $volume doesn't exist -- nothing to summarize" >&2
    exit 1
}
echo "[dhis2]"
# shellcheck disable=SC2016 # runs in the container
docker run --rm --network none --mount "type=volume,source=$volume,target=/d,readonly" \
    --entrypoint sh "$ALPINE_IMAGE" -c '
        count() { if [ -d "/d/$1" ]; then find "/d/$1" -type f | wc -l; else echo 0; fi; }
        echo "files $(count files)"
        echo "apps $(count apps)"
        if [ -f /d/.dhis2-version ]; then echo "version $(cat /d/.dhis2-version)"; else echo "version none"; fi
    '
