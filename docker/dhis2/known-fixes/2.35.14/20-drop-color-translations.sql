-- Known fix, not run automatically: add it with --extra-sql-dir if the 2.35 step fails dropping these
-- tables (constraints from before DHIS2 used migrations). Drops color set translations.
DROP TABLE IF EXISTS colorsettranslations CASCADE;
DROP TABLE IF EXISTS colorrsettranslations CASCADE; -- as spelled on the Malawi upgrade page
DROP TABLE IF EXISTS colortranslations CASCADE;
