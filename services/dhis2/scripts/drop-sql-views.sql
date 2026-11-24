-- Drops the database views of DHIS2's SQL views (views and materialized views named _view_*), as
-- DHIS2's Data Administration -> Maintenance -> "Drop SQL views" does: a migration that changes a
-- column one of them reads fails otherwise. Their definitions stay in DHIS2 (table sqlview), and
-- "Create SQL views" rebuilds them. Run by `pihx <instance> dhis2 upgrade` before each step. CASCADE:
-- one may read another; IF EXISTS: a cascade may already have dropped it. Other views are kept.
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT matviewname AS name FROM pg_matviews
             WHERE schemaname = 'public' AND matviewname LIKE '\_view\_%' LOOP
        EXECUTE format('DROP MATERIALIZED VIEW IF EXISTS public.%I CASCADE', r.name);
    END LOOP;
    FOR r IN SELECT viewname AS name FROM pg_views
             WHERE schemaname = 'public' AND viewname LIKE '\_view\_%' LOOP
        EXECUTE format('DROP VIEW IF EXISTS public.%I CASCADE', r.name);
    END LOOP;
END
$$;
