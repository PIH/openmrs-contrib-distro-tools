-- Before 2.31: rows pointing at user roles that no longer exist stop 2.31 adding its foreign key
-- ("violates foreign key constraint fk_program_userroles"). Removes only those rows.
DO $$
BEGIN
    IF to_regclass('program_userroles') IS NOT NULL AND to_regclass('userrole') IS NOT NULL THEN
        DELETE FROM program_userroles pu
        WHERE NOT EXISTS (SELECT 1 FROM userrole u WHERE u.userroleid = pu.userroleid);
    END IF;
END $$;
