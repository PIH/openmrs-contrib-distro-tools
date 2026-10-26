-- Known fix, not run automatically: add it with --extra-sql-dir if the 2.39 step fails on
-- program_attribute_group. 2.39's migration alters this table and then drops it, so after dropping a
-- table that couldn't be dropped normally, it has to exist again, empty (Malawi upgrade page).
DROP TABLE IF EXISTS program_attribute_group CASCADE;
CREATE TABLE program_attribute_group (
    programtrackedentityattributegroupid integer NOT NULL,
    uid character varying(11) NOT NULL,
    code character varying(50),
    created timestamp without time zone NOT NULL,
    lastupdated timestamp without time zone NOT NULL,
    lastupdatedby integer,
    name character varying(230) NOT NULL,
    shortname character varying(255),
    description text,
    uniqunessype bytea NOT NULL
);
