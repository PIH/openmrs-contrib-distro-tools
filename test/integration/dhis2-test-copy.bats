#!/usr/bin/env bats
# dhis2's test-copy guard (dhis2-test-copy) on synthetic schemas shaped like DHIS2 2.30's and 2.43's
# (column types as an empty 2.30 and 2.43.2.1 build them; never real data). It runs without DHIS2:
# Compose brings up dhis2-db and the guard only.

load ../helpers

setup() {
    cd "$BATS_TEST_TMPDIR"
    NAME="$(instance)"
    export DHIS2_DB_PASSWORD='Placeholder-1' DHIS2_DB_PORT=0 DHIS2_HTTP_PORT=0
    DHIS2_VERSION=2.43.2.1 "$BIN/pihx" "$NAME" create --services=dhis2-db,dhis2 >/dev/null
    # As pihx's start would (external volumes): only the database's, the guard has none.
    docker volume create --label "pihx.instance=$NAME" "${NAME}_dhis2-db-data" >/dev/null
    instance_compose_of "$NAME" up -d --wait dhis2-db >/dev/null 2>&1
}
teardown() {
    remove_test_instance "$NAME"
    common_teardown
}

sql() { # <sql>, in the instance's database
    docker exec -i "$NAME-dhis2-db" psql -U dhis -d dhis -v ON_ERROR_STOP=1 -qtA -c "$1"
}

# Runs the guard as a start does (Compose's up of dhis2-test-copy), waits for it, and prints its log
# (that run's only).
run_guard() {
    docker rm -f "$NAME-dhis2-test-copy" >/dev/null 2>&1 || true
    instance_compose_of "$NAME" up -d dhis2-test-copy >/dev/null 2>&1
    docker wait "$NAME-dhis2-test-copy" >/dev/null
    docker logs "$NAME-dhis2-test-copy" 2>&1
}

# 2.43: systemsetting.value text, jobconfiguration.jobtype varchar (with 2.43's other columns),
# the SMS gateways in the datastore (keyjsonvalue sms-config/config, since 2.42).
schema_243() {
    sql "
CREATE TABLE systemsetting (systemsettingid bigint PRIMARY KEY, name varchar(255) NOT NULL UNIQUE, value text);
CREATE TABLE jobconfiguration (jobconfigurationid bigint PRIMARY KEY, name varchar(230) NOT NULL,
    enabled boolean NOT NULL, jsonbjobparameters jsonb, jobtype varchar(120) NOT NULL,
    schedulingtype varchar(12) NOT NULL DEFAULT 'CRON', queuename varchar(50));
CREATE TABLE keyjsonvalue (keyjsonvalueid bigint PRIMARY KEY, namespace varchar(255) NOT NULL,
    namespacekey varchar(255) NOT NULL, jbvalue jsonb);
INSERT INTO systemsetting VALUES
    (1, 'keyEmailHostName', 'smtp.example.org'), (2, 'keyEmailPort', '587'), (3, 'keyEmailUsername', 'u'),
    (4, 'keyEmailPassword', 'p'), (5, 'keyEmailSender', 'a@example.org'), (6, 'keyEmailTls', 'true'),
    (7, 'keyRemoteInstanceUrl', 'https://remote.example.org'), (8, 'keyRemoteInstanceUsername', 'u'),
    (9, 'keyRemoteInstancePassword', 'p'), (10, 'keyFlag', 'lesotho');
INSERT INTO jobconfiguration (jobconfigurationid, name, enabled, jobtype) VALUES
    (1, 'notifications', true, 'PROGRAM_NOTIFICATIONS'), (2, 'messages', true, 'SEND_SCHEDULED_MESSAGE'),
    (3, 'data sync', true, 'DATA_SYNC'), (4, 'metadata sync', true, 'META_DATA_SYNC'),
    (5, 'event sync', true, 'SINGLE_EVENT_DATA_SYNC'), (6, 'tracker sync', true, 'TRACKED_ENTITY_DATA_SYNC'),
    (7, 'sms', true, 'SMS_SEND'), (8, 'push', true, 'HTML_PUSH_ANALYTICS'),
    (9, 'exchange', true, 'AGGREGATE_DATA_EXCHANGE'), (10, 'monitoring', true, 'MONITORING'),
    (11, 'dataset', true, 'DATA_SET_NOTIFICATION'), (12, 'credentials', true, 'CREDENTIALS_EXPIRY_ALERT'),
    (13, 'accounts', true, 'ACCOUNT_EXPIRY_ALERT'), (14, 'validation', true, 'VALIDATION_RESULTS_NOTIFICATION'),
    (15, 'analytics', true, 'ANALYTICS_TABLE'), (16, 'housekeeping', true, 'HOUSEKEEPING'),
    (17, 'already off', false, 'DATA_STATISTICS');
INSERT INTO keyjsonvalue VALUES (1, 'sms-config', 'config', '{\"gateways\": [{\"name\": \"g\"}]}'),
    (2, 'other-app', 'config', '{\"a\": 1}');"
}

# 2.30: systemsetting.value and jobconfiguration.jobtype are Java-serialized (bytea). A JobType is
# serialized as below (taken from an empty 2.30's own rows): the class, then 0x74, the name's length
# in two bytes and the name.
schema_230() {
    sql "
CREATE FUNCTION pg_temp.job_type(name text) RETURNS bytea LANGUAGE sql AS \$\$
    SELECT decode('aced00057e7200206f72672e686973702e646869732e7363686564756c696e672e4a6f6254797065'
                  '00000000000000001200007872000e6a6176612e6c616e672e456e756d00000000000000001200007870'
                  '7400' || lpad(to_hex(length(name)), 2, '0'), 'hex') || convert_to(name, 'UTF8') \$\$;
CREATE TABLE systemsetting (systemsettingid integer PRIMARY KEY, name varchar(255) NOT NULL UNIQUE, value bytea);
CREATE TABLE jobconfiguration (jobconfigurationid integer PRIMARY KEY, name varchar(230) NOT NULL,
    jobtype bytea NOT NULL, enabled boolean NOT NULL, jobparameters bytea);
INSERT INTO systemsetting VALUES
    (1, 'keyEmailHostName', '\\xaced0005'), (2, 'keyEmailPassword', '\\xaced0005'),
    (3, 'keySmsSetting', '\\xaced0005'), (4, 'keyRemoteInstanceUrl', '\\xaced0005'),
    (5, 'keyFlag', '\\xaced0005');
INSERT INTO jobconfiguration (jobconfigurationid, name, jobtype, enabled) VALUES
    (1, 'notifications', pg_temp.job_type('PROGRAM_NOTIFICATIONS'), true),
    (2, 'data sync', pg_temp.job_type('DATA_SYNC'), true),
    (3, 'program sync', pg_temp.job_type('PROGRAM_DATA_SYNC'), true),
    (4, 'push', pg_temp.job_type('PUSH_ANALYSIS'), true),
    (5, 'kafka', pg_temp.job_type('KAFKA_TRACKER'), true),
    (6, 'analytics', pg_temp.job_type('ANALYTICS_TABLE'), true),
    (7, 'statistics', pg_temp.job_type('DATA_STATISTICS'), true);"
}

@test "test-copy guard turns off email settings and sending jobs, and leaves other jobs alone" {
    schema_243
    set_env_value "$NAME" dhis2 DHIS2_TEST_COPY true
    run run_guard
    assert_output "dhis2-test-copy: outbound email and sending jobs turned off"
    run docker inspect -f '{{.State.ExitCode}}' "$NAME-dhis2-test-copy"
    assert_output 0
    run sql "SELECT name FROM systemsetting ORDER BY name"
    assert_output keyFlag
    run sql "SELECT jobtype FROM jobconfiguration WHERE enabled ORDER BY jobtype"
    assert_output $'ANALYTICS_TABLE\nHOUSEKEEPING'
    run sql "SELECT namespace FROM keyjsonvalue"
    assert_output other-app
    # Every start: a second run, after an admin turned a job back on, turns it off again.
    sql "UPDATE jobconfiguration SET enabled = true WHERE jobtype = 'DATA_SYNC'"
    run run_guard
    assert_output "dhis2-test-copy: outbound email and sending jobs turned off"
    run sql "SELECT count(*) FROM jobconfiguration WHERE enabled"
    assert_output 2
}

@test "test-copy guard works on the 2.30-shaped schema" {
    schema_230
    set_env_value "$NAME" dhis2 DHIS2_TEST_COPY true
    run run_guard
    assert_output "dhis2-test-copy: outbound email and sending jobs turned off"
    run docker inspect -f '{{.State.ExitCode}}' "$NAME-dhis2-test-copy"
    assert_output 0
    run sql "SELECT name FROM systemsetting ORDER BY name"
    assert_output keyFlag
    run sql "SELECT name FROM jobconfiguration WHERE enabled ORDER BY name"
    assert_output $'analytics\nstatistics'
}

@test "test-copy guard passes on an empty database (DHIS2 hasn't made its tables yet)" {
    set_env_value "$NAME" dhis2 DHIS2_TEST_COPY true
    run run_guard
    assert_output "dhis2-test-copy: outbound email and sending jobs turned off"
    run docker inspect -f '{{.State.ExitCode}}' "$NAME-dhis2-test-copy"
    assert_output 0
}

@test "test-copy guard changes nothing when DHIS2_TEST_COPY is false" {
    schema_243
    run run_guard
    assert_output "dhis2-test-copy: not a test copy, nothing changed"
    run docker inspect -f '{{.State.ExitCode}}' "$NAME-dhis2-test-copy"
    assert_output 0
    run sql "SELECT count(*) FROM systemsetting"
    assert_output 10
    run sql "SELECT count(*) FROM jobconfiguration WHERE enabled"
    assert_output 16
    run sql "SELECT count(*) FROM keyjsonvalue"
    assert_output 2
}

@test "test-copy guard fails on a schema it doesn't know, printing only SQL states, never values" {
    sql "CREATE TABLE jobconfiguration (jobconfigurationid bigint PRIMARY KEY, name varchar(230), enabled boolean, jobtype integer);
         CREATE TABLE systemsetting (systemsettingid bigint PRIMARY KEY, name varchar(255) NOT NULL UNIQUE, value text);
         INSERT INTO systemsetting VALUES (1, 'keyFlag', 'secret-row');"
    set_env_value "$NAME" dhis2 DHIS2_TEST_COPY true
    run run_guard
    assert_line --partial "ERROR:  PX002"
    assert_line "error: dhis2-test-copy: test-copy.sql failed with the SQL state above (PX001, PX002: a schema it doesn't know; see test-copy.sql), and changed nothing"
    refute_output --partial "the test-copy guard doesn't know"
    refute_output --partial integer
    run docker inspect -f '{{.State.ExitCode}}' "$NAME-dhis2-test-copy"
    refute_output 0
}

@test "test-copy guard fails a start when DHIS2_TEST_COPY is neither true nor false" {
    schema_243
    set_env_value "$NAME" dhis2 DHIS2_TEST_COPY yes
    run run_guard
    assert_output "error: DHIS2_TEST_COPY must be true or false"
    run docker inspect -f '{{.State.ExitCode}}' "$NAME-dhis2-test-copy"
    assert_output 1
}

@test "test-copy guard runs before dhis2 starts" {
    instance_compose_of "$NAME" config --format json > config.json
    run jq -r '.services.dhis2.depends_on["dhis2-test-copy"].condition' config.json
    assert_output service_completed_successfully
    run sed -n 's/^setup: *//p' "$REPO_ROOT/services/dhis2/service.yaml"
    assert_output "[dhis2-setup, dhis2-test-copy]"
}
