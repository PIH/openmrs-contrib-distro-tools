-- Known fix, not run automatically: choose it with --with-fix if the 2.41 step fails on
-- V2_41_24__TrackedEntityInstanceToTrackedEntity.sql with 'relation "trackedentity" already exists'
-- (SQL state 42P07). That migration renames trackedentityinstance to trackedentity, and its
-- trackedentityinstanceid column to trackedentityid. A database upgraded from much older versions can
-- still have their trackedentity table (columns name, description: tracked entity types before they
-- were renamed trackedentitytype), and trackedentityinstance can still have that era's trackedentityid
-- column pointing at it (lsdata does: a table of one row, a column set on 6 tracked entities). Both are
-- kept, renamed _legacy, with the primary key's index (index names are schema-wide: a later migration
-- may name trackedentity_pkey) and the foreign key. Each rename only where the legacy shape is there.
DO $$
BEGIN
    IF to_regclass('trackedentityinstance') IS NOT NULL AND EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = current_schema() AND table_name = 'trackedentity' AND column_name = 'name')
       AND NOT EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = current_schema() AND table_name = 'trackedentity' AND column_name = 'trackedentityinstanceid') THEN
        ALTER TABLE trackedentity RENAME TO trackedentity_legacy;
        IF EXISTS (SELECT 1 FROM pg_constraint
                   WHERE conrelid = 'trackedentity_legacy'::regclass AND conname = 'trackedentity_pkey') THEN
            ALTER TABLE trackedentity_legacy RENAME CONSTRAINT trackedentity_pkey TO trackedentity_legacy_pkey;
        END IF;
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = current_schema() AND table_name = 'trackedentityinstance'
                 AND column_name = 'trackedentityid')
       AND EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = current_schema() AND table_name = 'trackedentityinstance'
                 AND column_name = 'trackedentityinstanceid') THEN
        ALTER TABLE trackedentityinstance RENAME COLUMN trackedentityid TO trackedentityid_legacy;
        IF EXISTS (SELECT 1 FROM pg_constraint
                   WHERE conrelid = 'trackedentityinstance'::regclass
                     AND conname = 'fk_trackedentityinstance_trackedentityid') THEN
            ALTER TABLE trackedentityinstance RENAME CONSTRAINT fk_trackedentityinstance_trackedentityid
                TO fk_trackedentityinstance_trackedentityid_legacy;
        END IF;
    END IF;
END
$$;
