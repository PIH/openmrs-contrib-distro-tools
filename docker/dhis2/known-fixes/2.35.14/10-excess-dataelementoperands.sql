-- Known fix, not run automatically: add it with --extra-sql-dir if the 2.35 step fails on
-- dataelementoperand. Pivot tables saved before 2.35 could create data element operands nothing uses
-- (Malawi upgrade page, MLW-1563). Deletes the operands no data set section or data set refers to.
DO $$
BEGIN
    IF to_regclass('dataelementoperand') IS NOT NULL THEN
        DELETE FROM dataelementoperand o
        WHERE NOT EXISTS (SELECT 1 FROM sectiongreyedfields s WHERE s.dataelementoperandid = o.dataelementoperandid)
          AND NOT EXISTS (SELECT 1 FROM datasetoperands d WHERE d.dataelementoperandid = o.dataelementoperandid);
    END IF;
END $$;
