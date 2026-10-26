# Upgrading DHIS2

DHIS2's database migrations can't skip versions, and each version needs its own Java, so an upgrade
steps through the final patch of every version in between. `docker/dhis2/upgrade-path` lists them,
each with the Tomcat image that has its Java and its release WAR's URL and SHA-256. It replaces the
procedure on the Confluence page "Malawi DHIS2 Upgrade" (MLW-1563), which it's based on, and
starts at 2.30. DHIS2 publishes 2.30 only as a rolling build of its branch, so the path's 2.30 can be
a later build than a server runs (lsdata's is older; see the comment in `upgrade-path`). Check a
server's build before relying on that: `build.revision` in `build.properties` inside the WAR's
`WEB-INF/lib/dhis-service-core-*.jar`.

`openmrs-utils dhis2-upgrade --instance=<name>` does the stepping: for each version it fetches the WAR,
stops DHIS2, runs that version's SQL, sets `DHIS2_VERSION` and `DHIS2_IMAGE_TAG` in `env`, starts the
instance, waits for DHIS2 to come up (up to `DHIS2_UPGRADE_STEP_TIMEOUT`, two hours by default), shows
any migration errors from its log, and asks before going on. Answer anything but `y` to stop; run it
again to carry on from the version the instance is on. `--to=<version>` stops earlier. Every step is
logged, with its duration, to `<instance dir>/dhis2-upgrade.log`.

## Before

1. Take a backup: `ARCHIVE_PASSWORD=... openmrs-docker <name> backup --output-dir=<dir>`.
2. In DHIS2: Data Administration → Maintenance → *Drop SQL views*.
3. If puppet manages the instance, hold it: `/etc/puppet/build-disabled-<name>`. Otherwise its next
   apply puts the old version back into `env` in the middle of the upgrade.

## During

```bash
openmrs-utils dhis2-upgrade --instance=<name> [--to=<version>] [--extra-sql-dir=<dir>]
```

SQL in `docker/dhis2/upgrade-sql/<version>/` runs before that version starts, every time. Only fixes
that remove rows already breaking a constraint are there:

| Before | Fix |
|---|---|
| 2.31.9 | `program_userroles` rows for user roles that no longer exist (otherwise: `violates foreign key constraint "fk_program_userroles"`) |

When a step fails, its log (`openmrs-docker <name> logs dhis2`) names the migration. If it's one of
the known failures below, copy that fix into a directory of your own as `<version>/<file>.sql` and
pass `--extra-sql-dir=<dir>`; the same goes for a fix of your own, which is run after the built-in
files for that version. Each known fix says which error it answers, and is safe to run twice; none
runs unless you add it, since some drop tables a later migration would otherwise read.

| Version | Known fix (`docker/dhis2/known-fixes/`) | When |
|---|---|---|
| 2.35.14 | `10-excess-dataelementoperands.sql` | The step fails on `dataelementoperand` |
| 2.35.14 | `20-drop-color-translations.sql` | The step can't drop `colorsettranslations` / `colortranslations` |
| 2.37.10 | `10-drop-old-translation-tables.sql` | The step can't drop `charttranslations`, `reporttabletranslations`, `dashboarditem_*` or `objecttranslation`. Try without it first: the 2.37 migration reads `objecttranslation` |
| 2.39.10.1 | `10-recreate-program-attribute-group.sql` | The step fails on `program_attribute_group` |
| 2.41.8.1 | `10-rename-legacy-trackedentityaudit.sql` | The step fails on `V2_41_24__TrackedEntityInstanceToTrackedEntity.sql`: `relation "trackedentityaudit" already exists` (a leftover from much older versions; kept as `trackedentityaudit_legacy`) |

After a failed migration, Flyway may refuse to start again until its failed row is gone:

```sql
DELETE FROM flyway_schema_history WHERE success = false;
```

Then run `dhis2-upgrade` again: `env` already names the failed version, so it starts that version
again. To redo its SQL as well, set `DHIS2_VERSION` and `DHIS2_IMAGE_TAG` back to the previous
version first.

Known warnings that don't stop a step: from 2.34, *Could not perform upgrade of table
'trackedentityattributevalue'. Column 'value' should be altered to data type varchar(1200) and receive
a new index* asks for a manual change (see DHIS2's 2.34 upgrade notes); 2.35's *Invalid cron
expression* in the log4j setup defaults to daily.

## After

1. In DHIS2: Data Administration → Maintenance: clear and rebuild indexes, *Create SQL views*.
2. Data Administration → Analytics tables: export them (they're not in `backup-pgdump`'s backups).
3. Set the final `DHIS2_VERSION` and `DHIS2_IMAGE_TAG` where the instance is defined (puppet's
   `site.pp`), and release the hold.

## Rehearsing

Rehearse an upgrade of a production server on a test instance first, until it runs clean, restoring
a fresh production backup each round (`openmrs-docker <name> destroy`, `create` with the production
server's version, `dhis2-war`, `initialize`, start, then the steps above). Add each fix it needs
to the site's own SQL directory, so the production upgrade runs the same ones. The step durations in
`dhis2-upgrade.log` tell you how long a window the production upgrade needs.
