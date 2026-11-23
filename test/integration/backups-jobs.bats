#!/usr/bin/env bats
# The backup job and cleanup (services/backups/scripts), in the backup-tools image, with fixture scripts
# as the services' backup scripts.

load ../helpers

IMAGE="partnersinhealth/backup-tools:$("$REPO_ROOT/utils/hash-directory.sh" "$REPO_ROOT/images/backup-tools")"

# The image at this checkout's tag: published, or built here (as pihx would).
setup_file() {
    docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull -q "$IMAGE" >/dev/null 2>&1 \
        || docker build -q -t "$IMAGE" "$REPO_ROOT/images/backup-tools" >/dev/null
}

setup() {
    cd "$BATS_TEST_TMPDIR"
    VOL="$(res backups)"
    docker volume create "$VOL" >/dev/null
    FIX="$BATS_TEST_TMPDIR/fixtures"
    mkdir -p "$FIX"
    fixture() { mkdir -p "$FIX/$1"; echo "$FIX/$1/backup.sh"; } # <svc>: where its script goes
    # Fixture service scripts: write a file named after the service into the run folder, write nothing,
    # or fail.
    printf '#!/bin/bash\necho a > "$BACKUP_RUN_DIR/ok-a.txt"\n' > "$(fixture ok-a)"
    printf '#!/bin/bash\necho b > "$BACKUP_RUN_DIR/ok-b.txt"\n' > "$(fixture ok-b)"
    printf '#!/bin/bash\necho "boom" >&2\nexit 3\n' > "$(fixture fails)"
    printf '#!/bin/bash\necho "nothing chosen"\n' > "$(fixture writes-nothing)"
    printf '#!/bin/bash\necho z > "$BACKUP_RUN_DIR/half.7z"\nexit 2\n' > "$(fixture half)"
}
teardown() { common_teardown; }

# Runs a command in the backup image, with the volume at /backups, the checkout mounted as in
# backup.yaml, and the fixtures as the services' scripts. Extra docker args come first, ending in --.
in_image() { # [docker run args...] -- <command...>
    local args=()
    while [ "$1" != -- ]; do args+=("$1"); shift; done
    shift
    docker run --rm -v "$VOL:/backups" -v "$REPO_ROOT/services/backups/scripts:/opt/backup:ro" \
        -v "$FIX:/fixtures:ro" \
        -e BACKUP_SERVICES_DIR=/fixtures -e BACKUP_PREFIX=p \
        -e BACKUP_ARCHIVE_PASSWORD="${PW-pw-1}" ${args[@]+"${args[@]}"} --entrypoint bash "$IMAGE" "$@"
}

backup_job() { # [docker run args...] --
    in_image "$@" /opt/backup/backup.sh
}

runs() { in_image -- -c 'ls /backups' | grep -v -e status.json; }

@test "a complete run is renamed from .partial and recorded" {
    run backup_job -e BACKUP_PLAN="ok-a=script ok-b=script" --
    assert_success
    run runs
    assert_output --regexp '^p_[0-9]{8}T[0-9]{6}Z$'
    local run_name="$output"
    run in_image -- -c "ls /backups/$run_name"
    assert_output "$(printf 'backup.log\nok-a.txt\nok-b.txt')"
    run in_image -- -c 'jq -r .backup.last_result /backups/status.json'
    assert_output success
    run in_image -- -c 'jq -r ".backup | [.last_run, .last_error, (.last_success | length), (.last_attempt | length)] | @tsv" /backups/status.json'
    assert_output "$(printf '%s\t\t20\t20' "$run_name")"
}

@test "a second run while one is going exits with an error line, leaving the first's status alone" {
    run in_image -e BACKUP_PLAN=ok-a=script -- -c '
        ( flock 8; sleep 5 ) 8>/backups/.backup.lock &
        sleep 1
        /opt/backup/backup.sh; echo "exit $?"; wait'
    assert_output --partial 'error: backup not started: another backup is running'
    assert_output --partial 'exit 1'
    run runs
    assert_output ''
    run in_image -- -c 'ls /backups/status.json 2>&1'
    assert_output --partial 'No such file'
}

@test "a failing script fails the run but the others still run, and earlier runs are left" {
    in_image -- -c 'mkdir /backups/p_20200101T000000Z && echo old > /backups/p_20200101T000000Z/a.txt'
    run backup_job -e BACKUP_PLAN="fails=script ok-b=script half=script" --
    assert_failure
    assert_equal "${lines[-1]:0:6}" error:
    assert_output --regexp 'error: backup p_[0-9]{8}T[0-9]{6}Z failed: fails failed \(exit 3\); half failed \(exit 2\)$'
    run runs
    assert_line p_20200101T000000Z
    assert_line --regexp '^p_[0-9]{8}T[0-9]{6}Z\.failed$'
    local failed
    failed=$(runs | grep '\.failed$')
    # Only the log is kept: ok-b ran (its archive is gone with the rest), half's partial archive too.
    run in_image -- -c "ls /backups/$failed"
    assert_output backup.log
    run in_image -- -c "cat /backups/$failed/backup.log"
    assert_output --partial 'ok-b: done'
    assert_output --partial boom
    run in_image -- -c 'cat /backups/p_20200101T000000Z/a.txt'
    assert_output old
    run in_image -- -c 'jq -r ".backup | .last_result + \" \" + .last_error" /backups/status.json'
    assert_output --partial 'failed fails failed (exit 3)'
}

@test "a service whose plan says unset is reported not backed up, and one that says none is logged" {
    run backup_job -e BACKUP_PLAN="ok-a=script nope=unset quiet=none" --
    assert_success
    run in_image -- -c 'jq -c .backup.not_backed_up /backups/status.json'
    assert_output '["nope"]'
    run runs
    assert_output --regexp '^p_[0-9]{8}T[0-9]{6}Z$'
    run in_image -- -c 'cat /backups/p_*/backup.log'
    assert_output --partial 'nope: not backed up (it has no backup script)'
    assert_output --partial 'quiet: nothing to back up'
}

@test "a service whose script writes nothing named after it is reported not backed up" {
    printf '#!/bin/bash\necho x > "$BACKUP_RUN_DIR/someone-else.txt"\n' > "$(fixture misnamed)"
    run backup_job -e BACKUP_PLAN="ok-a=script writes-nothing=script misnamed=script" --
    assert_success
    run in_image -- -c 'jq -c .backup.not_backed_up /backups/status.json'
    assert_output '["writes-nothing","misnamed"]'
    run in_image -- -c 'cat /backups/p_*/backup.log'
    assert_output --partial 'nothing chosen'
    assert_output --partial 'writes-nothing: not backed up (its script wrote nothing)'
    refute_output --partial 'writes-nothing: done'
}

@test "a run where no service wrote a backup fails, and an empty plan is refused" {
    for plan in "nope=unset" "quiet=none"; do
        run backup_job -e BACKUP_PLAN="$plan" --
        assert_failure
        assert_output --regexp 'error: backup p_[0-9]{8}T[0-9]{6}Z failed: no service wrote a backup$'
        run runs
        assert_output --regexp '^p_[0-9]{8}T[0-9]{6}Z\.failed$'
        in_image -- -c 'rm -rf /backups/p_*'
    done
    run backup_job -e BACKUP_PLAN= --
    assert_failure
    assert_output --partial 'error: backup failed: BACKUP_PLAN is empty'
}

@test "a service whose plan says script but whose script isn't mounted fails the run" {
    run backup_job -e BACKUP_PLAN="ok-a=script missing=script odd=weird" --
    assert_failure
    assert_output --partial "missing: its backup script isn't mounted at /fixtures/missing/backup.sh (services/missing/with-backups.yaml)"
    assert_output --partial "odd: unknown backup kind 'weird' in BACKUP_PLAN"
}

@test "a run without the newest run's size plus BACKUP_MIN_FREE free fails before any script runs" {
    run backup_job -e BACKUP_PLAN=ok-a=script -e BACKUP_MIN_FREE=999999999G --
    assert_failure
    assert_output --regexp 'failed: not enough free space in /backups: [0-9]+ bytes free, [0-9]+ needed'
    refute_output --partial 'ok-a: backing up'
    run runs
    assert_output --regexp '^p_[0-9]{8}T[0-9]{6}Z\.failed$'
    run backup_job -e BACKUP_PLAN=ok-a=script -e BACKUP_MIN_FREE=1K --
    assert_success
}

@test "BACKUP_MIN_FREE must be a byte count, or one with a K, M or G suffix" {
    for v in 2g 1.5G G -1 2T "2 G"; do
        run backup_job -e BACKUP_PLAN=ok-a=script -e BACKUP_MIN_FREE="$v" --
        assert_failure
        assert_output --partial "error: backup failed: BACKUP_MIN_FREE must be"
    done
    run runs
    assert_output ''
}

@test "the entrypoint refuses an invalid schedule with an error line" {
    run in_image -e BACKUP_SCHEDULE='61 * * * *' -e BACKUP_UPLOAD_SCHEDULE='15 * * * *' -- /opt/backup/entrypoint.sh
    assert_failure
    assert_equal "${lines[-1]:0:6}" error:
    assert_output --partial "invalid BACKUP_SCHEDULE or BACKUP_UPLOAD_SCHEDULE: '61 * * * *'"
}

@test "a run that can't start is recorded as failed, ending with an error line" {
    run backup_job -e BACKUP_PLAN=ok-a=script --
    assert_success
    # A df that prints nothing usable, first on PATH.
    printf '#!/bin/bash\necho garbage\n' > "$FIX/df"
    chmod +x "$FIX/df"
    run in_image -e PATH="/fixtures:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" -e BACKUP_PLAN=ok-a=script -- /opt/backup/backup.sh
    assert_failure
    assert_equal "${lines[-1]:0:6}" error:
    run in_image -- -c 'jq -r ".backup | [.last_result, .last_error] | @tsv" /backups/status.json; jq -r ".backup.last_success | length" /backups/status.json'
    assert_output --regexp '^failed	couldn.t determine the free space.*
20$'
    run runs
    assert_equal "${#lines[@]}" 1
}

@test "refusing without a password is recorded too" {
    PW= run backup_job -e BACKUP_PLAN=ok-a=script --
    assert_failure
    run in_image -- -c 'jq -r ".backup.last_result" /backups/status.json'
    assert_output failed
}

@test "a prefix that can't name a directory is refused" {
    for prefix in "" "a/b" ".x" "a b"; do
        run backup_job -e BACKUP_PREFIX="$prefix" -e BACKUP_PLAN=ok-a=script --
        assert_failure
        assert_output --partial 'error: backup failed: BACKUP_PREFIX must'
    done
    run runs
    assert_output ''
}

@test "refuses without BACKUP_ARCHIVE_PASSWORD" {
    PW= run backup_job -e BACKUP_PLAN=ok-a=script --
    assert_failure
    assert_output --partial BACKUP_ARCHIVE_PASSWORD
    run runs
    assert_output ''
}

@test "local-only cleanup keeps BACKUP_KEEP_LOCAL complete runs" {
    in_image -- -c 'for i in 1 2 3 4 5; do mkdir /backups/p_2020010${i}T000000Z; done
        mkdir /backups/p_20200102T000001Z.failed /backups/p_20200106T000000Z.failed'
    run in_image -e BACKUP_KEEP_LOCAL=3 -- /opt/backup/cleanup.sh --local-only
    assert_success
    run runs
    # The failed run older than the newest complete one goes too; a newer one stays.
    assert_output "$(printf 'p_20200103T000000Z\np_20200104T000000Z\np_20200105T000000Z\np_20200106T000000Z.failed')"
    run in_image -e BACKUP_KEEP_LOCAL=all -- /opt/backup/cleanup.sh --local-only
    assert_success
    run runs
    assert_output --partial p_20200103T000000Z
}

@test "cleanup with all keeps every run" {
    in_image -- -c 'for i in 1 2 3 4 5; do mkdir /backups/p_2020010${i}T000000Z; done'
    run in_image -e BACKUP_KEEP_LOCAL=all -- /opt/backup/cleanup.sh --local-only
    assert_success
    run runs
    assert_equal "${#lines[@]}" 5
}

@test "uploaded cleanup deletes only uploaded runs beyond the newest kept" {
    in_image -- -c 'for i in 1 2 3 4; do mkdir /backups/p_2020010${i}T000000Z; done
        mkdir /backups/.uploaded; touch /backups/.uploaded/p_20200101T000000Z /backups/.uploaded/p_20200103T000000Z'
    run in_image -e BACKUP_KEEP_LOCAL=2 -- /opt/backup/cleanup.sh --uploaded
    assert_success
    run runs
    assert_output "$(printf 'p_20200102T000000Z\np_20200103T000000Z\np_20200104T000000Z')"
}

@test "local-only cleanup deletes a stale .partial but not one newer than the newest complete run" {
    in_image -- -c 'mkdir /backups/p_20200101T000000Z.partial /backups/p_20200102T000000Z /backups/p_20200103T000000Z.partial'
    run in_image -e BACKUP_KEEP_LOCAL=3 -- /opt/backup/cleanup.sh --local-only
    assert_success
    run runs
    assert_output "$(printf 'p_20200102T000000Z\np_20200103T000000Z.partial')"
}

@test "cleanup requires BACKUP_KEEP_LOCAL of 1 or more, or all" {
    in_image -- -c 'mkdir /backups/p_20200101T000000Z'
    for v in 0 -1 abc; do
        run in_image -e BACKUP_KEEP_LOCAL="$v" -- /opt/backup/cleanup.sh --local-only
        assert_failure
        assert_output --regexp '^error: BACKUP_KEEP_LOCAL'
    done
    run runs
    assert_output p_20200101T000000Z
}

@test "cleanup deletes azcopy logs and plans older than 14 days, in either mode" {
    in_image -- -c 'mkdir -p /backups/.azcopy/logs /backups/.azcopy/plans /backups/p_20200101T000000Z
        touch /backups/.azcopy/logs/new.log /backups/.azcopy/plans/new.steV
        touch -d "20 days ago" /backups/.azcopy/logs/old.log /backups/.azcopy/plans/old.steV'
    run in_image -e BACKUP_KEEP_LOCAL=all -- /opt/backup/cleanup.sh --local-only
    assert_success
    run in_image -- -c 'ls /backups/.azcopy/logs /backups/.azcopy/plans'
    refute_output --partial old
    assert_output --partial new.log
    assert_output --partial new.steV
}

@test "status_set leaves status.json as it was when jq fails" {
    run in_image -- -c 'echo "{\"a\":{\"b\":\"1\"}}" > /backups/status.json
        source /opt/backup/lib.sh
        status_set --json a c "not json"; echo "exit $?"; cat /backups/status.json; ls -A /backups'
    assert_output --partial 'exit 1'
    assert_output --partial '{"a":{"b":"1"}}'
    refute_output --partial status.json.tmp
}

