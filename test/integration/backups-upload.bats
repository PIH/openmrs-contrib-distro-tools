#!/usr/bin/env bats
# The upload job and the cleanup after it (services/backups/scripts/upload.sh, cleanup.sh), in the backup
# image with test/fixtures/azcopy-stub as azcopy.

load ../helpers

IMAGE="partnersinhealth/backup-tools:$("$REPO_ROOT/utils/hash-directory.sh" "$REPO_ROOT/images/backup-tools")"
SAS='sv=2024&sig=SECRETSIG'

# The image at this checkout's tag: published, or built here (as pihx would).
setup_file() {
    docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull -q "$IMAGE" >/dev/null 2>&1 \
        || docker build -q -t "$IMAGE" "$REPO_ROOT/images/backup-tools" >/dev/null
}

setup() {
    cd "$BATS_TEST_TMPDIR"
    VOL="$(res backups)"
    STORE="$(res store)"
    docker volume create "$VOL" >/dev/null
    docker volume create "$STORE" >/dev/null
}
teardown() { common_teardown; }

in_image() { # [docker run args...] -- <command...>
    local args=()
    while [ "$1" != -- ]; do args+=("$1"); shift; done
    shift
    # REAL_AZCOPY=1: the image's own azcopy, not the stub.
    local stub=(-v "$REPO_ROOT/test/fixtures/azcopy-stub:/usr/local/bin/azcopy:ro")
    [ -z "${REAL_AZCOPY:-}" ] || stub=()
    docker run --rm -v "$VOL:/backups" -v "$STORE:/store" -v "$REPO_ROOT/services/backups/scripts:/opt/backup:ro" \
        ${stub[@]+"${stub[@]}"} \
        -e BACKUP_PREFIX=p -e STUB_STORE=/store \
        ${args[@]+"${args[@]}"} --entrypoint bash "$IMAGE" "$@"
}

upload_job() { # [docker run args...] --
    in_image -e BACKUP_UPLOAD=azure -e BACKUP_AZURE_URL=https://acct.blob.core.windows.net/cont \
        -e BACKUP_AZURE_PATH=site/inst -e BACKUP_AZURE_SAS="$SAS" "$@" /opt/backup/upload.sh
}

# Makes runs in the volume: <name>... each with a.txt (3 bytes) and b.txt (5 bytes)
make_runs() {
    local cmd='cd /backups' n
    for n in "$@"; do cmd+="; mkdir $n; printf abc > $n/a.txt; printf abcde > $n/b.txt"; done
    in_image -- -c "$cmd"
}
mark_uploaded() { in_image -- -c "mkdir -p /backups/.uploaded; cd /backups/.uploaded; touch $*"; }
volume_runs() { in_image -- -c 'ls /backups' | grep -v -e status.json; }

@test "uploads complete runs oldest first and marks them" {
    make_runs p_20200102T000000Z p_20200101T000000Z p_20200103T000000Z.partial p_20200104T000000Z.failed
    run upload_job --
    assert_success
    run in_image -- -c 'ls /store/cont/site/inst; ls /backups/.uploaded; grep -c "" /store/.calls'
    assert_output "$(printf 'p_20200101T000000Z\np_20200102T000000Z\np_20200101T000000Z\np_20200102T000000Z\n4')"
    run in_image -- -c 'grep "^copy" /store/.calls'
    assert_line --index 0 --partial -- '--overwrite=false'
    assert_line --index 0 --partial -- '--from-to LocalBlob'
    assert_line --index 0 --partial /backups/p_20200101T000000Z
    assert_line --index 1 --partial /backups/p_20200102T000000Z
    run in_image -- -c 'ls /store/cont/site/inst/p_20200101T000000Z'
    assert_output "$(printf 'a.txt\nb.txt')"
    run in_image -- -c 'jq -r ".upload | [.last_result, .last_error, (.last_success | length), (.last_attempt | length), .pending_runs, .pending_bytes] | @tsv" /backups/status.json'
    assert_output "$(printf 'success\t\t20\t20\t0\t0')"
}

@test "the SAS token never reaches the output or the calls log" {
    make_runs p_20200101T000000Z
    run upload_job --
    assert_success
    refute_output --partial SECRETSIG
    run in_image -- -c 'cat /store/.calls'
    refute_output --partial SECRETSIG
    run in_image -- -c 'grep -rl SECRETSIG /backups || true'
    assert_output ""
}

@test "the SAS token is redacted from a failing azcopy's output" {
    make_runs p_20200101T000000Z
    in_image -- -c "touch /store/.fail-always; echo 'failed: https://acct.blob.core.windows.net/cont/x/?$SAS now' > /store/.fail-message"
    run upload_job --
    assert_failure
    refute_output --partial SECRETSIG
    assert_output --partial 'failed: https://acct.blob.core.windows.net/cont/x/?REDACTED now'
    assert_line --regexp '^error: '
}

@test "keeps a run whose listing doesn't match" {
    make_runs p_20200101T000000Z
    in_image -- -c 'echo b.txt > /store/.list-short'
    run upload_job --
    assert_failure
    assert_line --regexp '^error: .*p_20200101T000000Z'
    run in_image -- -c '[ ! -e /backups/.uploaded/p_20200101T000000Z ] && ls /backups/p_20200101T000000Z'
    assert_success
    run in_image -- -c 'jq -r ".upload | [.last_result, .last_error, .pending_runs, .pending_bytes] | @tsv" /backups/status.json'
    assert_output --regexp '^failed	.*p_20200101T000000Z.*	1	8$'
}

@test "retries a failed upload on the next run" {
    make_runs p_20200101T000000Z
    in_image -- -c 'touch /store/.fail-once'
    run upload_job --
    assert_failure
    run in_image -- -c 'jq -r .upload.last_result /backups/status.json; ls /backups/.uploaded 2>/dev/null | wc -l'
    assert_output "$(printf 'failed\n0')"
    run upload_job --
    assert_success
    run in_image -- -c 'jq -r .upload.last_result /backups/status.json; ls /backups/.uploaded'
    assert_output "$(printf 'success\np_20200101T000000Z')"
}

@test "never deletes an unuploaded run, keeps the newest N uploaded" {
    make_runs p_20200101T000000Z p_20200102T000000Z p_20200103T000000Z p_20200104T000000Z p_20200105T000000Z p_20200106T000000Z
    mark_uploaded p_20200101T000000Z p_20200102T000000Z p_20200103T000000Z p_20200104T000000Z p_20200106T000000Z
    # the stub is down, so nothing new uploads (and p_20200105 stays unuploaded)
    run in_image -e BACKUP_KEEP_LOCAL=2 -- /opt/backup/cleanup.sh --uploaded
    assert_success
    run volume_runs
    assert_output "$(printf 'p_20200105T000000Z\np_20200106T000000Z')"

    make_runs p_20200101T000000Z p_20200102T000000Z
    mark_uploaded p_20200101T000000Z p_20200102T000000Z
    run in_image -e BACKUP_KEEP_LOCAL=all -- /opt/backup/cleanup.sh --uploaded
    assert_success
    run volume_runs
    assert_output "$(printf 'p_20200101T000000Z\np_20200102T000000Z\np_20200105T000000Z\np_20200106T000000Z')"
}

@test "upload then cleanup: unuploaded runs survive a failed upload" {
    make_runs p_20200101T000000Z p_20200102T000000Z p_20200103T000000Z
    in_image -- -c 'touch /store/.fail-once'
    run upload_job -e BACKUP_KEEP_LOCAL=1 --
    assert_failure
    run volume_runs
    # the first (failed) run is kept, the others uploaded; the newest is kept, the middle one goes
    assert_output "$(printf 'p_20200101T000000Z\np_20200103T000000Z')"
}

@test "cleans up a stale .partial and old .failed once a newer run completes" {
    make_runs p_20200101T000000Z.partial p_20200102T000000Z.failed p_20200103T000000Z p_20200104T000000Z.partial
    run upload_job -e BACKUP_KEEP_LOCAL=3 --
    assert_success
    run volume_runs
    assert_output "$(printf 'p_20200103T000000Z\np_20200104T000000Z.partial')"
}

@test "does nothing without BACKUP_UPLOAD, even with the Azure settings" {
    make_runs p_20200101T000000Z
    run in_image -e BACKUP_AZURE_URL=https://a.b/c -e BACKUP_AZURE_SAS=x -- /opt/backup/upload.sh
    assert_success
    run in_image -- -c 'ls -A /store; ls /backups'
    assert_output p_20200101T000000Z
}

@test "an unknown BACKUP_UPLOAD fails, recorded in status, and uploads nothing" {
    make_runs p_20200101T000000Z
    local v
    for v in s3 ../upload-azure 'azure x'; do
        run in_image -e BACKUP_UPLOAD="$v" -- /opt/backup/upload.sh
        assert_failure
        assert_output "error: upload failed: BACKUP_UPLOAD is '$v': it must be empty (no uploads) or azure"
    done
    run in_image -- -c 'ls -A /store; ls /backups/.uploaded 2>/dev/null; jq -r .upload.last_result /backups/status.json'
    assert_output failed
}

@test "azure without its URL or SAS fails and says which" {
    make_runs p_20200101T000000Z
    run in_image -e BACKUP_UPLOAD=azure -e BACKUP_AZURE_SAS=x -- /opt/backup/upload.sh
    assert_failure
    assert_output "error: upload failed: BACKUP_AZURE_URL must be set"
    run in_image -e BACKUP_UPLOAD=azure -e BACKUP_AZURE_URL=https://a.b/c -- /opt/backup/upload.sh
    assert_failure
    assert_output "error: upload failed: BACKUP_AZURE_SAS must be set"
    run in_image -- -c 'ls -A /store'
    assert_output ""
}

@test "pending counts in status" {
    make_runs p_20200101T000000Z p_20200102T000000Z
    in_image -- -c 'touch /store/.fail-always'
    run upload_job --
    assert_failure
    run in_image -- -c 'jq -r ".upload | [.pending_runs, .pending_bytes] | @tsv" /backups/status.json'
    assert_output "$(printf '2\t16')"
}

@test "an upload already running makes this one say so and fail" {
    make_runs p_20200101T000000Z
    run in_image -e BACKUP_UPLOAD=azure -e BACKUP_AZURE_URL=https://a.b/c -e BACKUP_AZURE_SAS=x -- -c \
        'flock /backups/.upload.lock sleep 5 & sleep 1; /opt/backup/upload.sh'
    assert_failure
    assert_output "error: another upload is running; this one did nothing"
}

@test "azcopy's logs and plans are kept in the volume, out of the runs, and its buffer and concurrency capped" {
    make_runs p_20200101T000000Z
    run upload_job --
    assert_success
    run in_image -- -c 'cat /store/.env'
    assert_output "/backups/.azcopy/logs /backups/.azcopy/plans 0.25 4"
    run volume_runs
    assert_output p_20200101T000000Z
}

# --- the real azcopy, against the Azurite emulator ----------------------------------------------------

AZURITE_IMAGE=mcr.microsoft.com/azure-storage/azurite:3.35.0
AZURITE_KEY='Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw=='

# An account SAS (blob, rwdlacx) for Azurite's well-known account, signed with its well-known key.
azurite_sas() {
    perl -MDigest::SHA=hmac_sha256 -MMIME::Base64 -MURI::Escape -e '
        my ($acct, $key) = @ARGV;
        my ($sp, $ss, $srt, $se, $sv) = ("rwdlacx", "b", "sco", "2099-01-01T00:00:00Z", "2022-11-02");
        my $s = join("\n", $acct, $sp, $ss, $srt, "", $se, "", "https,http", $sv, "") . "\n";
        my $sig = encode_base64(hmac_sha256($s, decode_base64($key)), "");
        print "sv=$sv&ss=$ss&srt=$srt&sp=$sp&se=" . uri_escape($se) . "&spr=https,http&sig=" . uri_escape($sig);
    ' devstoreaccount1 "$AZURITE_KEY"
}

@test "real azcopy: uploads two runs to Azurite, and a second upload sends nothing new" {
    local net az sas ip
    net="$(res net)"; az="$(res azurite)"; sas="$(azurite_sas)"
    docker network create "$net" >/dev/null
    docker run -d --name "$az" --network "$net" "$AZURITE_IMAGE" \
        azurite-blob --blobHost 0.0.0.0 --skipApiVersionCheck >/dev/null
    local deadline=$(( $(date +%s) + 60 ))
    until docker logs "$az" 2>&1 | grep -q 'successfully listens'; do
        [ "$(date +%s)" -lt "$deadline" ] || { docker logs "$az" >&2; fail "Azurite didn't start"; }
        sleep 1
    done
    docker exec "$az" node -e 'require("http").request({host: "127.0.0.1", port: 10000, method: "PUT",
        path: "/devstoreaccount1/cont?restype=container&" + process.argv[1],
        headers: {"x-ms-version": "2022-11-02", "content-length": 0}},
        r => process.exit(r.statusCode === 201 ? 0 : 1)).end()' "$sas"
    # azcopy treats a host name as an account's own endpoint, so the emulator is reached by address.
    ip=$(docker inspect "$az" --format "{{(index .NetworkSettings.Networks \"$net\").IPAddress}}")

    make_runs p_20200101T000000Z p_20200102T000000Z
    in_image -- -c 'head -c 1572864 /dev/zero > /backups/p_20200101T000000Z/big.bin'
    local env=(--network "$net" -e REAL_AZCOPY=1 -e BACKUP_UPLOAD=azure
        -e BACKUP_AZURE_URL="http://$ip:10000/devstoreaccount1/cont"
        -e BACKUP_AZURE_PATH=site/inst -e BACKUP_AZURE_SAS="$sas")

    REAL_AZCOPY=1 run upload_job "${env[@]:0}" --
    assert_success
    refute_output --partial "${sas##*sig=}"
    assert_output --partial 'Total Number of Bytes Transferred: 1572872'
    run in_image -- -c 'ls /backups/.uploaded'
    assert_output "$(printf 'p_20200101T000000Z\np_20200102T000000Z')"
    run in_image -- -c 'jq -r ".upload | [.last_result, .pending_runs, .pending_bytes] | @tsv" /backups/status.json'
    assert_output "$(printf 'success\t0\t0')"

    # Forget the markers: the second job finds every file in Azure, sends none, and verifies them.
    in_image -- -c 'rm /backups/.uploaded/*'
    REAL_AZCOPY=1 run upload_job "${env[@]:0}" --
    assert_success
    assert_output --partial 'Total Number of Bytes Transferred: 0'
    refute_output --partial 'Total Number of Bytes Transferred: 1'
    run in_image -- -c 'ls /backups/.uploaded'
    assert_output "$(printf 'p_20200101T000000Z\np_20200102T000000Z')"
}
