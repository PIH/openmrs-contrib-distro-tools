-- Known fix, not run automatically: add it with --extra-sql-dir if the 2.41 step fails on
-- V2_41_24__TrackedEntityInstanceToTrackedEntity.sql with 'relation "trackedentityaudit" already
-- exists'. That migration renames trackedentityinstanceaudit to trackedentityaudit; a database that
-- has been upgraded from much older versions can still have their trackedentityaudit (columns visitor
-- and accessedmodule), which no later version uses (DHIS2's 2.30 demo database has one; lsdata doesn't).
-- It's kept, renamed to trackedentityaudit_legacy, rather than dropped.
DO $$
BEGIN
    IF to_regclass('trackedentityinstanceaudit') IS NOT NULL AND EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = current_schema() AND table_name = 'trackedentityaudit' AND column_name = 'visitor') THEN
        ALTER TABLE trackedentityaudit RENAME TO trackedentityaudit_legacy;
    END IF;
END
$$;
