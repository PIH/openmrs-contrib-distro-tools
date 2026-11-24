-- Known fix, not run automatically: choose it with --with-fix when upgrading from 2.30 a database with
-- tracked entities that have no type. 2.42 makes the type required (V2_42_26__Add_not_null_constraint_
-- to_trackedentity.sql, SQL state P0001; DHIS2's 2.42 migration notes, "Null Tracked Entity Type"): it
-- gives a typeless tracked entity the type of a program it's enrolled in, and stops on any it can't.
-- Done here, before the first step, so every migration after 2.30 sees typed tracked entities. On
-- 2.30's tables (trackedentityinstance, programinstance), a typeless tracked entity gets, in order:
--   1. the type of a program it's enrolled in that has one (2.42's own rule; the earliest enrollment);
--   2. else the current type named as its pre-2.29 one: the trackedentity table from before types
--      were renamed trackedentitytype, which its legacy trackedentityid column still points at.
-- One with neither is left alone, so 2.42 still stops on it. lsdata: 3 enrolled (QI- Person), 3 by
-- name (Person). Nothing is deleted; review such records in DHIS2 afterwards.
DO $$
BEGIN
    IF to_regclass('trackedentityinstance') IS NULL OR to_regclass('programinstance') IS NULL THEN
        RETURN;  -- not 2.30's tables
    END IF;
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

    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = current_schema() AND table_name = 'trackedentityinstance'
                 AND column_name = 'trackedentityid')
       AND EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = current_schema() AND table_name = 'trackedentity' AND column_name = 'name') THEN
        -- Only a name that matches exactly one current type.
        EXECUTE $sql$
            UPDATE trackedentityinstance tei
            SET trackedentitytypeid = tt.trackedentitytypeid
            FROM trackedentity legacy
            JOIN trackedentitytype tt ON tt.name = legacy.name
            WHERE tei.trackedentitytypeid IS NULL
              AND tei.trackedentityid = legacy.trackedentityid
              AND (SELECT count(*) FROM trackedentitytype t2 WHERE t2.name = legacy.name) = 1
        $sql$;
    END IF;
END
$$;
