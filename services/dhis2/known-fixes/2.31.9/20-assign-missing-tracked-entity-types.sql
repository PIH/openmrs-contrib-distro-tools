-- Known fix, not run automatically: choose it with --with-fix when upgrading from 2.30 a database that
-- still has tracked entities with no type, or the tables from before 2.29 renamed tracked entity types
-- (lsdata has both). Two later steps fail otherwise:
--   2.41: V2_41_24__TrackedEntityInstanceToTrackedEntity.sql renames trackedentityinstance to
--         trackedentity, which still exists (the pre-2.29 types table): 'relation "trackedentity"
--         already exists' (SQL state 42P07);
--   2.42: V2_42_26__Add_not_null_constraint_to_trackedentity.sql makes the type required and stops
--         (SQL state P0001) on any tracked entity it can't type from an enrollment (DHIS2's 2.42
--         migration notes, "Null Tracked Entity Type").
-- On 2.30's tables, before the first step, so every migration after 2.30 sees typed tracked entities:
-- 1. A typeless tracked entity gets, best evidence first:
--    a. the type of a program it's enrolled in that has one (2.42's own rule; the earliest enrollment);
--    b. else the one type whose attributes include every attribute it has a value for;
--    c. else the current type named as its pre-2.29 one, if exactly one has that name.
--    One with none of these keeps no type, so 2.42 still stops on it.
-- 2. Then, unless a typeless tracked entity still points at it, what's left from before 2.29 is
--    dropped: the trackedentity table, the trackedentityid columns of trackedentityinstance and
--    program, and the trackedentityattributevalues table if empty. No version since 2.29 reads them.
-- lsdata: 6 typeless tracked entities, all QI- Person (3 by enrollment, 3 by their QI- attributes); the
-- pre-2.29 type they pointed at was a generic "Person" from 2017, not today's (training) Person.
DO $$
DECLARE
    fk record;
BEGIN
    IF to_regclass('trackedentityinstance') IS NULL OR to_regclass('programinstance') IS NULL THEN
        RETURN;  -- not 2.30's tables
    END IF;

    -- 1a. A program it's enrolled in.
    UPDATE trackedentityinstance tei
    SET trackedentitytypeid = (
        SELECT p.trackedentitytypeid
        FROM programinstance pi JOIN program p ON p.programid = pi.programid
        WHERE pi.trackedentityinstanceid = tei.trackedentityinstanceid AND p.trackedentitytypeid IS NOT NULL
        ORDER BY pi.programinstanceid
        LIMIT 1)
    WHERE tei.trackedentitytypeid IS NULL
      AND EXISTS (
        SELECT 1 FROM programinstance pi JOIN program p ON p.programid = pi.programid
        WHERE pi.trackedentityinstanceid = tei.trackedentityinstanceid AND p.trackedentitytypeid IS NOT NULL);

    -- 1b. The one type whose attributes include all of its values' attributes.
    UPDATE trackedentityinstance tei
    SET trackedentitytypeid = fit.trackedentitytypeid
    FROM (
        SELECT v.trackedentityinstanceid, min(tt.trackedentitytypeid) AS trackedentitytypeid
        FROM (SELECT DISTINCT trackedentityinstanceid FROM trackedentityattributevalue) v
        JOIN trackedentitytype tt ON NOT EXISTS (
            SELECT 1 FROM trackedentityattributevalue own
            WHERE own.trackedentityinstanceid = v.trackedentityinstanceid
              AND NOT EXISTS (SELECT 1 FROM trackedentitytypeattribute tta
                              WHERE tta.trackedentitytypeid = tt.trackedentitytypeid
                                AND tta.trackedentityattributeid = own.trackedentityattributeid))
        GROUP BY v.trackedentityinstanceid
        HAVING count(*) = 1) fit
    WHERE tei.trackedentitytypeid IS NULL AND tei.trackedentityinstanceid = fit.trackedentityinstanceid;

    IF NOT (EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = current_schema() AND table_name = 'trackedentityinstance'
                      AND column_name = 'trackedentityid')
            AND EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = current_schema() AND table_name = 'trackedentity' AND column_name = 'name')) THEN
        RETURN;  -- no pre-2.29 leftovers
    END IF;

    -- 1c. The current type named as its pre-2.29 one (dynamic: the tables may not exist).
    EXECUTE $sql$
        UPDATE trackedentityinstance tei
        SET trackedentitytypeid = tt.trackedentitytypeid
        FROM trackedentity legacy
        JOIN trackedentitytype tt ON tt.name = legacy.name
        WHERE tei.trackedentitytypeid IS NULL
          AND tei.trackedentityid = legacy.trackedentityid
          AND (SELECT count(*) FROM trackedentitytype t2 WHERE t2.name = legacy.name) = 1
    $sql$;

    -- 2. The leftovers, all or none: not while a typeless tracked entity points at them, nor while the
    -- old join table holds rows. Foreign keys to the old table go first, from any table (2.30 still
    -- uses trackedentitytranslations, for the current types, which has one): only the constraints,
    -- never their tables. The table itself without CASCADE, so anything else on it (a view) fails the fix.
    IF EXISTS (SELECT 1 FROM trackedentityinstance WHERE trackedentitytypeid IS NULL AND trackedentityid IS NOT NULL) THEN
        RETURN;
    END IF;
    IF to_regclass('trackedentityattributevalues') IS NOT NULL THEN
        IF EXISTS (SELECT 1 FROM trackedentityattributevalues) THEN
            RETURN;
        END IF;
        DROP TABLE trackedentityattributevalues;
    END IF;
    FOR fk IN SELECT conrelid::regclass AS tbl, conname FROM pg_constraint
              WHERE confrelid = 'trackedentity'::regclass AND contype = 'f' LOOP
        EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', fk.tbl, fk.conname);
    END LOOP;
    ALTER TABLE trackedentityinstance DROP COLUMN trackedentityid;
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = current_schema() AND table_name = 'program' AND column_name = 'trackedentityid') THEN
        ALTER TABLE program DROP COLUMN trackedentityid;
    END IF;
    DROP TABLE trackedentity;
END
$$;
