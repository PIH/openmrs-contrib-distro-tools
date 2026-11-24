# DHIS2: upgrading, patching and test copies

How to move a DHIS2 instance (services [`dhis2-db`](../services/dhis2-db/README.md) and
[`dhis2`](../services/dhis2/README.md)) to a newer DHIS2, and how to refresh a test copy of
production. It replaces the procedure on the Confluence page "Malawi DHIS2 Upgrade" (MLW-1563),
which it's based on.

**DHIS2's database migrations can't be undone, and can't skip a minor version.** An instance only
ever moves forward, one version of [`scripts/versions`](../services/dhis2/scripts/versions) at a
time. `dhis2-setup` refuses to start a version older than the last one started, or one more than one
step past it.

## Upgrading

```bash
pihx <name> dhis2 upgrade [--to=<version>] [--with-fix=<version>/<file>]...
```

One run steps to the next version in the versions list, or through each one up to `--to`. For each
step it:

1. starts `dhis2-db` (an instance just restored with `initialize` has no containers yet) and waits
   for it, then stops `dhis2`. An instance never started or initialized has no database volume, and
   is refused;
2. drops DHIS2's SQL views (views and materialized views named `_view_*`), as Data Administration →
   Maintenance → *Drop SQL views* does, if there are any: a migration can't change a column one
   reads ([`scripts/drop-sql-views.sql`](../services/dhis2/scripts/drop-sql-views.sql)). Their
   definitions stay in DHIS2; *Create SQL views* rebuilds them after the upgrade (below);
3. runs the known fixes chosen with `--with-fix` for that version, each in one transaction;
4. sets `DHIS2_VERSION` and `DHIS2_TOMCAT_TAG` in the instance's `dhis2.env` to the step's;
5. starts the instance (`dhis2-setup` fetches the WAR) and waits for DHIS2 to come up, its
   migrations included: up to `DHIS2_UPGRADE_STEP_TIMEOUT` seconds (default 7200; set it in
   `dhis2.env`);
6. appends `<UTC time> <from> -> <to> fixes=[...] <seconds>s ok|failed` to
   `<instance dir>/dhis2-upgrade.log`.

It holds the instance lock throughout. At the end it prints `<name> is on DHIS2 <version>.`, and on a
Puppet host (whose instance `tools` is Puppet's checkout) a reminder to set the new `DHIS2_VERSION`
and `DHIS2_TOMCAT_TAG` in `site.pp`.

### Before

1. Take a backup (`pihx <name> backup`, [Backups](backups.md)).
2. On a Puppet host, hold the instance (`/etc/puppet/build-disabled-<name>`). Otherwise its next
   apply puts the old version back into `dhis2.env`, and `dhis2-setup` then refuses to start it.
3. Run the upgrade outside the backup schedule (`BACKUP_SCHEDULE`, default 01:30): a scheduled
   backup doesn't take the instance lock, and its `pg_dump` holds locks on every table it dumps, which
   slows or blocks a step's migrations for as long as it runs.

### When a step fails

`upgrade` never prints log text, from DHIS2, its setup containers or Postgres, since their messages
can quote row values (`Key (id)=(...)`). On a copy of production, its output is safe to pass on. The
whole logs stay on the machine (`docker logs <name>-dhis2`, `pihx <name> logs <service>`). A step
ends in one of three ways:

- **DHIS2 failed to come up**: `DHIS2 <version> didn't come up.` and, for each failed Flyway
  migration in that step's log, its version and description, its file and the SQL state, for
  example:

  ```
  DHIS2 2.41.11.0 didn't come up.
    migration 2.41.24 - TrackedEntityInstanceToTrackedEntity failed
    migration V2_41_24__TrackedEntityInstanceToTrackedEntity.sql failed
    SQL state 42P07
  ```

  With `(no failed migration recognised in its log)` instead, read the log on the machine.
- **A setup container failed**: `DHIS2 <version> didn't start: a setup container failed`. The
  reason is in `pihx <name> logs dhis2-setup` or `dhis2-test-copy`
  ([When a start fails](../services/dhis2/README.md#when-a-start-fails)).
- **The wait timed out with DHIS2 still starting**: `DHIS2 <version> hasn't come up within <n>s,
  but is still starting`. Its migrations may still be running: **don't stop it**. Wait until
  `pihx <name> status` shows `<name>-dhis2` healthy, then run `upgrade` again to finish the step. Until
  then `upgrade` refuses to run (`<name>-dhis2 is still starting`), rather than stopping DHIS2
  mid-migration. Still starting means running and not yet healthy: `starting`, or `unhealthy`, which
  its healthcheck reports once its two-hour `start_period` is over though a long migration may still
  be running. The step's wait doesn't give up on `unhealthy` either: only a failed deploy in the log,
  the container stopping, or `DHIS2_UPGRADE_STEP_TIMEOUT` ends it. A DHIS2 that has logged a failed
  deploy doesn't count as starting. One that stays unhealthy without that, its log showing no
  migration running, can be stopped by hand (`pihx <name> stop`) before running `upgrade` again.

`dhis2.env` already names the failed version, and `<instance dir>/dhis2-upgrade.pending` records that
it hasn't come up. Run `upgrade` again and it **retries that version**, never going past it: the
chosen fixes, then the start. The same goes for a run interrupted while a version was starting. A
fix that fails is rolled back, and leaves DHIS2 stopped on the version it was on.

If the failure is a known one below, run the step again with its fix. After a failed migration,
Flyway may refuse to start again until its failed row is gone; before the retry:

```bash
pihx <name> compose exec dhis2-db psql -U dhis -d dhis -c 'DELETE FROM flyway_schema_history WHERE success = false'
```

### Known fixes

[`services/dhis2/known-fixes/<version>/`](../services/dhis2/known-fixes) holds fixes for failures
other upgrades have hit. None runs unless chosen with `--with-fix=<version>/<file>`, since some drop
tables a later migration would otherwise read. Each says which error it answers, and is safe to run
twice. A fix needed in a rehearsal goes into the repo here (marked if it's specific to one site), so
the production upgrade runs the same one.

| Version | Fix | When |
|---|---|---|
| 2.31.9 | `10-orphaned-program-userroles.sql` | `violates foreign key constraint "fk_program_userroles"` (rows for user roles that no longer exist) |
| 2.31.9 | `20-assign-missing-tracked-entity-types.sql` | from 2.30, when tracked entities have no type, or the tables from before 2.29 renamed tracked entity types are still there. Otherwise 2.41's `V2_41_24__TrackedEntityInstanceToTrackedEntity.sql` fails with `relation "trackedentity" already exists` and 2.42's `V2_42_26__Add_not_null_constraint_to_trackedentity.sql` stops (SQL state P0001). Types each by its enrolled program, else by its attribute values, else by its pre-2.29 type's name; then drops the pre-2.29 tables and columns, unless a typeless one still needs them (lsdata: 6, all QI- Person) |
| 2.35.14 | `10-excess-dataelementoperands.sql` | the step fails on `dataelementoperand` |
| 2.35.14 | `20-drop-color-translations.sql` | the step can't drop `colorsettranslations` / `colortranslations` |
| 2.37.10 | `10-drop-old-translation-tables.sql` | the step can't drop `charttranslations`, `reporttabletranslations`, `dashboarditem_*` or `objecttranslation`. Try without it first: the 2.37 migration reads `objecttranslation` |
| 2.39.10.1 | `10-recreate-program-attribute-group.sql` | the step fails on `program_attribute_group` |
| 2.41.11.0 | `10-rename-legacy-trackedentityaudit.sql` | `V2_41_24__TrackedEntityInstanceToTrackedEntity.sql`: `relation "trackedentityaudit" already exists` (a leftover from much older versions; kept as `trackedentityaudit_legacy`) |

Known warnings that don't stop a step: from 2.34, *Could not perform upgrade of table
'trackedentityattributevalue'. Column 'value' should be altered to data type varchar(1200)* asks
for a manual change (DHIS2's 2.34 upgrade notes); 2.35's *Invalid cron expression* in the log4j
setup defaults to daily.

### After

1. If nobody here has a login on the source: `pihx <name> dhis2 reset-password [<username>]`, then
   `pihx <name> start` ([Resetting a password](../services/dhis2/README.md#resetting-a-password)).
2. Data Administration → Maintenance, with these ticked, then *Perform maintenance*:
   *Create SQL views* (`upgrade` dropped them), *Update category option combinations*, *Update
   organisation unit paths*, *Clear application cache* and *Reload apps*. Leave the *Remove…*,
   *Permanently remove…* and *Prune periods* options alone: they delete data. (2.4x has no *Rebuild
   indexes*.)
3. Scheduler: open the *Analytics* job (analytics tables), check its settings and save it, then
   *Run now* and see it complete. A job made on 2.3x keeps that version's settings (e.g. *Last
   years* 0), and its first run on 2.43 can fail. Check that every job that ran before is still
   enabled with the schedule you expect; on a test copy, `dhis2-test-copy` keeps the sending ones
   (notifications, alerts, sync) off on purpose.
4. Data Administration → Analytics tables: export them (the `dhis2-db` backup leaves their rows out,
   and dashboards stay empty until they're built).
5. Check what users use: data entry for a recent period, Capture (tracker and event programs),
   the main dashboards once analytics is done, and a quick look at each app in use. Apps shown in
   App Management that can't be uninstalled are DHIS2's own bundled ones, at the version it ships.
6. On a Puppet host, set the final `DHIS2_VERSION` and `DHIS2_TOMCAT_TAG` in `site.pp`, then release
   the hold.

What changes for users from 2.3x: the old web apps were replaced (Tracker Capture and Event Capture
by Capture, the old data entry screen by the Data Entry app, pivot tables and charts by Data
Visualizer), so bookmarks into old app paths break, and users may need to clear their browser cache
once. Logins and passwords carry over. Outside DHIS2, check the DHIS2 Android Capture versions in
use, and every API client: the old tracker API (`/api/trackedEntityInstances`, `/api/events`, ...)
is gone from 2.41, replaced by `/api/tracker`.

### Rehearsing

Rehearse a production upgrade on a test copy first, until it runs clean, from a fresh production
backup each round ([below](#refreshing-a-test-copy-from-production)). The step durations in
`dhis2-upgrade.log` tell you how long a window the production upgrade needs.

## Patching DHIS2

A newer patch of the version an instance runs (e.g. 2.43.3 on 2.43.2.1) is a new line in the versions
list ([Versions](../services/dhis2/README.md#versions)), after the one it replaces. Then either run
`pihx <name> dhis2 upgrade`, which steps to it like any other version, or set `DHIS2_VERSION` (and
`DHIS2_TOMCAT_TAG` if it differs) in the instance's env (`site.pp` on a Puppet host) and start it.
Take a backup first either way: a patch can carry migrations too.

## Refreshing a test copy from production

A test copy (lsdata-test) holds production's data, so it sets `DHIS2_TEST_COPY=true`, which turns
off outbound email and sending jobs at each `pihx <test> start` or `update`, before DHIS2 starts
([A copy of production](../services/dhis2/README.md#a-copy-of-production)). Not after a host reboot or
a Docker restart, which bring DHIS2 back without it: then run `pihx <test> stop && pihx <test> start`.
A start that doesn't recreate `dhis2` changes the rows under a running DHIS2, which may not see it
until it restarts.
To refresh it from a production backup run ([Restoring](backups.md#restoring)):

```bash
pihx <test> destroy                         # development hosts; on a Puppet host, remove its volumes by hand
DHIS2_VERSION=<production's version> DHIS2_TOMCAT_TAG=<its tag> DHIS2_TEST_COPY=true \
DHIS2_ENCRYPTION_PASSWORD=<production's> DHIS2_DB_PASSWORD=<...> \
    pihx <test> create --services=dhis2-db,dhis2
ARCHIVE_PASSWORD=<the archive password> pihx <test> initialize --from <run directory>
pihx <test> dhis2 reset-password [<username>]  # if nobody here has a login on the source
pihx <test> start
```

A large production database can take more than an hour to import: give `initialize` longer with
`PIHX_INITIALIZE_TIMEOUT=<seconds>` (default 3600, [Initializing an instance](restore.md)).

Then upgrade it as above if production is to be upgraded. Patient data stays on the host: the
rehearsal is run by a person, who passes on only what `upgrade` prints.

**`DHIS2_VERSION` must be the version the database last ran.** A backup taken by this service carries
the version marker, so `dhis2-setup` refuses a downgrade or a skip from it. A restore from a legacy
DHIS2 home (as at the cutover from a legacy server) has no marker, and nothing checks
`DHIS2_VERSION` against the database: set it to exactly the source's version. An earlier one would run
on a schema it doesn't know; a later one would run several versions' migrations at once.
