#!/bin/bash
# `pihx <instance> summary`: the [biometrics] section, each table's row count in biometrics.db (the
# fingerprint templates), read from the biometrics-data volume whether the server runs or not. Read
# with Python's sqlite3 in the pihx-runtime image (here already: pihx runs in it), as the volume's
# owner (BIOMETRICS_DATA_OWNER, default the image's 9000:9000), so a file SQLite creates beside the
# database (its WAL index) stays the server's. Run through pihx, which sets the environment
# (pihx/script.py).
set -euo pipefail
volume="${SERVICE_NAME}_biometrics-data"
docker volume inspect "$volume" >/dev/null 2>&1 || {
    echo "error: $volume doesn't exist -- nothing to summarize" >&2
    exit 1
}
image="partnersinhealth/pihx-runtime:$("$PIHX_TOOLS/utils/hash-directory.sh" "$PIHX_TOOLS/images/pihx-runtime")"
echo "[biometrics]"
# shellcheck disable=SC2016 # Python, not the shell
docker run --rm --network none --user "${BIOMETRICS_DATA_OWNER:-9000:9000}" \
    --mount "type=volume,source=$volume,target=/d" --entrypoint python3 "$image" -c '
import os, sqlite3
if not os.path.exists("/d/biometrics.db"):
    print("no biometrics.db")
    raise SystemExit
db = sqlite3.connect("file:/d/biometrics.db?mode=ro", uri=True)
tables = [r[0] for r in db.execute(
    "SELECT name FROM sqlite_master WHERE type = \"table\" AND name NOT LIKE \"sqlite_%\"")]
for table in sorted(tables):
    count = db.execute("SELECT COUNT(*) FROM \"%s\"" % table.replace("\"", "\"\"")).fetchone()[0]
    print("rows %s %d" % (table, count))
'
