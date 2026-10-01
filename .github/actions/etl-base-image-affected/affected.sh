#!/bin/bash
# Usage: affected.sh <Dockerfile> <build arg> <image> <published tags, as a JSON array>
#
# After <image> (e.g. partnersinhealth/petl) has been published with <published tags> (e.g.
# ["latest","3.8.0-SNAPSHOT"]), says whether the Dockerfile builds on one of them: its
# "ARG <build arg>=<image>:<tag>" default names <image> and one of those tags (no tag is latest).
# A different image, another tag, or a pinned digest isn't affected. Writes affected=true|false to
# $GITHUB_OUTPUT (when set) and prints why.
set -euo pipefail

[ $# -eq 4 ] || { sed -n '2,9s/^# \{0,1\}//p' "$0" >&2; exit 2; }
DOCKERFILE=$1 ARG=$2 IMAGE=$3 TAGS=$4

die() { echo "error: $*" >&2; exit 1; }
result() { # <true|false> <reason>
    echo "$2"
    [ -z "${GITHUB_OUTPUT:-}" ] || echo "affected=$1" >> "$GITHUB_OUTPUT"
    exit 0
}

[ -f "$DOCKERFILE" ] || die "$DOCKERFILE not found"
line=$(grep -m1 -E "^ARG[[:space:]]+$ARG=" "$DOCKERFILE") || die "no ARG $ARG=<image> default in $DOCKERFILE"
base=${line#*=}
base=${base//\"/}
base=${base//\'/}
mapfile -t tags < <(jq -r '.[]' <<< "$TAGS")
[ ${#tags[@]} -gt 0 ] || die "no published tags"

[[ "$base" != *@* ]] || result false "$DOCKERFILE builds on $base, pinned by digest: not affected"
name=${base%:*} tag=${base##*:}
if [ "$name" = "$base" ] || [[ "$tag" == */* ]]; then name=$base tag=latest; fi
[ "$name" = "$IMAGE" ] || result false "$DOCKERFILE builds on $name, not $IMAGE: not affected"
for t in "${tags[@]}"; do
    [ "$t" != "$tag" ] || result true "$DOCKERFILE builds on $IMAGE:$tag, which was just published: affected"
done
result false "$DOCKERFILE builds on $IMAGE:$tag; the published tags are ${tags[*]}: not affected"
