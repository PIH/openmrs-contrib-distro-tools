-- Known fix, not run automatically: add it with --extra-sql-dir only if the 2.37 step fails dropping
-- these tables. 2.37 moves translations into the objects themselves; dropping objecttranslation
-- before that migration has run loses them, so try the step without this first.
DROP TABLE IF EXISTS charttranslations CASCADE;
DROP TABLE IF EXISTS reporttabletranslations CASCADE;
DROP TABLE IF EXISTS dashboarditem_reporttables CASCADE;
DROP TABLE IF EXISTS dashboarditem_charts CASCADE;
DROP TABLE IF EXISTS objecttranslation CASCADE;
