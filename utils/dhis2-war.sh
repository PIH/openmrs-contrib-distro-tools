#!/bin/bash
# Fetches a DHIS2 release WAR, verified against its SHA-256, as dhis2-<version>.war: what a DHIS2
# instance's dhis2 service runs (its wars/ directory, see dhis2.yaml).
#
# Usage: openmrs-utils dhis2-war --version=<version> (--instance=<name> | --output-dir=<dir>)
#            [--url=<url> --sha256=<checksum>]
#   --version     a DHIS2 version in docker/dhis2/upgrade-path, which gives its URL and checksum;
#                 another version needs --url and --sha256
#   --instance    an openmrs-docker instance: its wars/ directory (under OPENMRS_DOCKER_HOME)
#   A file already there that verifies is kept; one that doesn't is replaced. A download that
#   doesn't verify is deleted. Needs curl, and sha256sum or shasum.
#   DHIS2_UPGRADE_PATH  replaces docker/dhis2/upgrade-path (tests)
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

VERSION=""
INSTANCE=""
OUTPUT_DIR=""
URL=""
SHA256=""
for arg in "$@"; do
    case "$arg" in
        --version=*) VERSION="${arg#*=}" ;;
        --instance=*) INSTANCE="${arg#*=}" ;;
        --output-dir=*) OUTPUT_DIR="${arg#*=}" ;;
        --url=*) URL="${arg#*=}" ;;
        --sha256=*) SHA256="${arg#*=}" ;;
        *) die "unknown argument: $arg" ;;
    esac
done
[ -n "$VERSION" ] && [ -n "$INSTANCE$OUTPUT_DIR" ] && { [ -z "$INSTANCE" ] || [ -z "$OUTPUT_DIR" ]; } || usage
[ -z "$INSTANCE" ] || OUTPUT_DIR="${OPENMRS_DOCKER_HOME:-$HOME/openmrs}/$INSTANCE/wars"
if [ -z "$URL$SHA256" ]; then
    read -r URL SHA256 < <(awk -v v="$VERSION" '$1 == v { print $3, $4 }' \
        "${DHIS2_UPGRADE_PATH:-$UTILS_DIR/../docker/dhis2/upgrade-path}") || true
    [ -n "$URL" ] || die "DHIS2 $VERSION isn't in docker/dhis2/upgrade-path: give its --url and --sha256"
fi
[ -n "$URL" ] && [ -n "$SHA256" ] || die "--url and --sha256 go together"

sha256_of() {
    if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}

mkdir -p "$OUTPUT_DIR"
TARGET="$OUTPUT_DIR/dhis2-$VERSION.war"
if [ -f "$TARGET" ] && [ "$(sha256_of "$TARGET")" = "$SHA256" ]; then
    note "$TARGET is already there and verified."
    exit 0
fi
PARTIAL="$TARGET.partial"
on_exit 'rm -f "$PARTIAL"'
note "Downloading DHIS2 $VERSION from $URL..."
curl -fsSL --retry 3 -o "$PARTIAL" "$URL" || die "couldn't download $URL"
ACTUAL=$(sha256_of "$PARTIAL")
[ "$ACTUAL" = "$SHA256" ] || die "the download's SHA-256 is $ACTUAL, not $SHA256: not using it"
mv -f "$PARTIAL" "$TARGET"
note "Fetched $TARGET."
