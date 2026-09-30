#!/bin/bash
# Edits the openmrs-runtime.properties in an OpenMRS data directory. openmrs-core 2.6+ writes that
# file on its first install and afterwards only merges OMRS_EXTRA_* properties into it, so other
# settings changed in env (e.g. connection.*) never reach an existing one.
#
# Usage: openmrs-utils runtime-properties --volume=<volume or dir> (--set-aside | --set)
#   --set-aside  renames it to openmrs-runtime.properties.restored, so OpenMRS writes a fresh one
#                from the instance's env on its next start (after a restore, it holds the source
#                server's settings)
#   --set        sets the key=value lines given on stdin (so secrets are on no command line),
#                replacing those keys' lines, in the properties format (a backslash doubled). The
#                file keeps its owner and mode; the previous one is openmrs-runtime.properties.bak.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

VOLUME=
MODE=
for arg in "$@"; do
    case "$arg" in
        --volume=*) VOLUME="${arg#*=}" ;;
        --set-aside|--set) [ -z "$MODE" ] || usage; MODE=$arg ;;
        *) die "unknown argument: $arg" ;;
    esac
done
[ -n "$VOLUME" ] && [ -n "$MODE" ] || usage
require_volume_or_dir "$VOLUME"

# In a container: the file is usually owned by the OpenMRS image's runtime user.
if [ "$MODE" = --set-aside ]; then
    docker run --rm -v "$VOLUME:/data" "$ALPINE_IMAGE" sh -c '
        f=/data/openmrs-runtime.properties
        [ -f "$f" ] || exit 0
        mv "$f" "$f.restored"
        echo "Moved openmrs-runtime.properties aside to openmrs-runtime.properties.restored -- OpenMRS will write a fresh one from the instance'"'"'s env on its next start."' >&2
    exit 0
fi

# shellcheck disable=SC2016
docker run -i --rm -v "$VOLUME:/data" "$ALPINE_IMAGE" sh -c '
    f=/data/openmrs-runtime.properties
    cat > /tmp/set
    [ -f "$f" ] || { echo "No openmrs-runtime.properties yet: OpenMRS writes it from env on its first start."; exit 0; }
    keys=$(sed "s/=.*//" /tmp/set)
    cp -p "$f" "$f.bak"
    { awk -v keys="$keys" "
          BEGIN { n = split(keys, k, \"\\n\"); for (i = 1; i <= n; i++) drop[k[i]] = 1 }
          { key = \$0; sub(/^[ \\t]+/, \"\", key); sub(/[ \\t]*[=:].*\$/, \"\", key); if (!(key in drop)) print }" "$f.bak"
      sed "s/\\\\/\\\\\\\\/g" /tmp/set
    } > /tmp/new && cat /tmp/new > "$f"
    echo "Set $(echo $keys | sed "s/ / and /g") in openmrs-runtime.properties (the previous file is openmrs-runtime.properties.bak)."' >&2
