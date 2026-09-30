#!/bin/bash
# Removes openmrs-module-initializer's configuration_checksums from an openmrs-data volume, so the
# next start reprocesses all configuration (e.g. after loading a different database under an
# existing openmrs-data).
#
# Usage: openmrs-utils clear-configuration-checksums --volume=<openmrs-data volume>
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

VOLUME=
for arg in "$@"; do
    case "$arg" in
        --volume=*) VOLUME="${arg#*=}" ;;
        *) die "unknown argument: $arg" ;;
    esac
done
[ -n "$VOLUME" ] || usage
require_volume_or_dir "$VOLUME"
refuse_if_in_use "$VOLUME"

note "Clearing configuration_checksums from $VOLUME..."
docker run --rm -v "$VOLUME:/data" "$ALPINE_IMAGE" rm -rf /data/configuration_checksums
note "Cleared configuration_checksums from $VOLUME. The next start will reprocess all configuration."
