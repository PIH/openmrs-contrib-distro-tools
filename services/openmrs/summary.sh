#!/bin/bash
# `pihx <instance> summary`: the [data-dir] section, the files and bytes per top-level directory of
# openmrs-data. By default without what the image supplies (modules, owa, configuration, frontend),
# as the backup leaves it out; PIHX_SUMMARY_INCLUDE_DISTRIBUTION_ARTIFACTS=true (summary
# --include-distribution-artifacts) includes it.
set -euo pipefail
volume="${SERVICE_NAME}_openmrs-data"
docker volume inspect "$volume" >/dev/null 2>&1 || {
    echo "error: $volume doesn't exist -- nothing to summarize" >&2
    exit 1
}
args=(--data-dir="$volume" --data-dir-only)
[ "${PIHX_SUMMARY_INCLUDE_DISTRIBUTION_ARTIFACTS:-}" = true ] || args+=(--exclude-distribution-artifacts)
exec "$PIHX_TOOLS/utils/fingerprint.sh" "${args[@]}"
