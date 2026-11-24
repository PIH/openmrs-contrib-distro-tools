-- dhis2-test-copy (test-copy.sh), on an instance with DHIS2_TEST_COPY=true, before every start of
-- DHIS2: a copy of production must not email or message anyone, or send data anywhere, even after an
-- admin turns any of it back on. Run in one transaction, with ON_ERROR_STOP.
--
-- Idempotent, and it works on every schema from 2.30 to 2.43: each part checks information_schema
-- first, and skips a table that isn't there (an empty database, before DHIS2's first start makes
-- its tables). A table that is there without the column it works by (PX001, PX003), or a column type
-- it doesn't know (PX002), fails the start rather than changing nothing.
--
-- The names below were checked (2026-11-23) against dhis2/dhis2-core: the JobType enum,
-- dhis-2/dhis-api/src/main/java/org/hisp/dhis/scheduling/JobType.java, on the 2.30 branch and every
-- upgrade step's tag up to 2.43.2.1; the setting keys in
-- dhis-2/dhis-services/dhis-service-setting/src/main/java/org/hisp/dhis/setting/SettingKey.java
-- (2.30) and dhis-2/dhis-api/src/main/java/org/hisp/dhis/setting/SystemSettings.java (2.43.2.1);
-- the column types in an empty 2.30 and 2.43.2.1 database.

-- 1. The email server and the remote instance (where DATA_SYNC and META_DATA_SYNC send to), in
-- every version, and the SMS gateways up to 2.41 (keySmsSetting). Without a host name DHIS2 sends
-- no email. The value's type (bytea up to 2.33, text from 2.34) doesn't matter here.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema = current_schema() AND table_name = 'systemsetting') THEN
        RETURN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = current_schema() AND table_name = 'systemsetting' AND column_name = 'name') THEN
        RAISE EXCEPTION 'systemsetting has no name column: the test-copy guard can''t delete the email settings'
            USING ERRCODE = 'PX003';
    END IF;
    DELETE FROM systemsetting WHERE name IN (
        'keyEmailHostName', 'keyEmailPort', 'keyEmailUsername', 'keyEmailPassword',
        'keyEmailSender', 'keyEmailTls',
        'keySmsSetting',
        'keyRemoteInstanceUrl', 'keyRemoteInstanceUsername', 'keyRemoteInstancePassword');
END $$;

-- 2. The SMS gateways from 2.42 on: the datastore entry sms-config/config (migration
-- V2_42_17__Move_sms_config_to_datastore.sql). Without it DHIS2 has no gateway.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema = current_schema() AND table_name = 'keyjsonvalue') THEN
        RETURN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = current_schema() AND table_name = 'keyjsonvalue' AND column_name = 'namespacekey') THEN
        RAISE EXCEPTION 'keyjsonvalue has no namespacekey column: the test-copy guard can''t delete the SMS gateways'
            USING ERRCODE = 'PX003';
    END IF;
    DELETE FROM keyjsonvalue WHERE namespace = 'sms-config' AND namespacekey = 'config';
END $$;

-- 3. Scheduled jobs that send data out or message people: off. Their type is varchar in later
-- versions and Java-serialized (bytea) in 2.30, where the value ends with 0x74, the name's length in
-- two bytes, and the name; matching that whole tail keeps DATA_SYNC from matching META_DATA_SYNC.
--   all versions: PROGRAM_NOTIFICATIONS, SEND_SCHEDULED_MESSAGE, DATA_SYNC, META_DATA_SYNC, SMS_SEND,
--     MONITORING, DATA_SET_NOTIFICATION, CREDENTIALS_EXPIRY_ALERT, VALIDATION_RESULTS_NOTIFICATION
--   PROGRAM_DATA_SYNC (2.30-2.40), EVENT_PROGRAMS_DATA_SYNC and TRACKER_PROGRAMS_DATA_SYNC (2.33-2.41),
--   SINGLE_EVENT_DATA_SYNC and TRACKED_ENTITY_DATA_SYNC (2.42-), PUSH_ANALYSIS (2.30-2.42),
--   HTML_PUSH_ANALYTICS (2.41-), KAFKA_TRACKER (2.30-2.31), ACCOUNT_EXPIRY_ALERT (2.37-),
--   AGGREGATE_DATA_EXCHANGE (2.39-)
DO $$
DECLARE
    job_types text[] := ARRAY[
        'PROGRAM_NOTIFICATIONS', 'SEND_SCHEDULED_MESSAGE', 'DATA_SYNC', 'META_DATA_SYNC', 'SMS_SEND',
        'MONITORING', 'DATA_SET_NOTIFICATION', 'CREDENTIALS_EXPIRY_ALERT',
        'VALIDATION_RESULTS_NOTIFICATION', 'PROGRAM_DATA_SYNC', 'EVENT_PROGRAMS_DATA_SYNC',
        'TRACKER_PROGRAMS_DATA_SYNC', 'SINGLE_EVENT_DATA_SYNC', 'TRACKED_ENTITY_DATA_SYNC',
        'PUSH_ANALYSIS', 'HTML_PUSH_ANALYTICS', 'KAFKA_TRACKER', 'ACCOUNT_EXPIRY_ALERT',
        'AGGREGATE_DATA_EXCHANGE'];
    job_type_column text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema = current_schema() AND table_name = 'jobconfiguration') THEN
        RETURN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = current_schema() AND table_name = 'jobconfiguration' AND column_name = 'enabled') THEN
        RAISE EXCEPTION 'jobconfiguration has no enabled column: the test-copy guard can''t turn jobs off'
            USING ERRCODE = 'PX001';
    END IF;
    SELECT data_type INTO job_type_column FROM information_schema.columns
        WHERE table_schema = current_schema() AND table_name = 'jobconfiguration' AND column_name = 'jobtype';
    IF job_type_column IN ('character varying', 'text') THEN
        UPDATE jobconfiguration SET enabled = false WHERE enabled AND jobtype = ANY (job_types);
    ELSIF job_type_column = 'bytea' THEN
        UPDATE jobconfiguration SET enabled = false
        WHERE enabled AND EXISTS (
            SELECT 1 FROM unnest(job_types) AS t(name)
            WHERE substring(jobtype FROM length(jobtype) - length(t.name) - 2)
                  = decode('7400' || lpad(to_hex(length(t.name)), 2, '0'), 'hex') || convert_to(t.name, 'UTF8'));
    ELSE
        RAISE EXCEPTION 'jobconfiguration.jobtype is %, which the test-copy guard doesn''t know', coalesce(job_type_column, 'missing')
            USING ERRCODE = 'PX002';
    END IF;
END $$;
