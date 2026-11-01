# Getting to know the tools

A walk-through of what `pihx` and `openmrs-docker` can do, in the order you'd meet it: a first
instance, looking inside it, backing it up and restoring it into another, seeds, developing a
distro, companion services, and getting rid of an instance safely. Each section is a few commands
to run yourself, with what to look for, and a link to the reference for the details.

The examples use the Sierra Leone distribution; any distro works the same way with its own image
and config profiles (its README lists them).

## 1. Install, and check

Install as in the [README](../README.md#install), then:

```bash
pihx version
```

It prints the tool's version, the tools directory it runs from, and the `pihx-runtime` image it
uses. `pihx` runs in that container, so Docker is all your machine needs; the first run pulls the
image (or builds it). Instances live in `~/pihx` (`PIHX_HOME`).

Run `pihx` or `openmrs-docker` with no arguments, at any point, for every command.

## 2. A first instance

```bash
OPENMRS_IMAGE_NAME=partnersinhealth/pihsl-emr \
OPENMRS_PIH_CONFIG=sierraLeone,sierraLeone-kgh,sierraLeone-kgh-ci \
openmrs-docker t1 create

ls -la ~/pihx/t1
```

`openmrs-docker` is `pihx` with OpenMRS additions: here, it picked OpenMRS's default services
(`openmrs-db` and `openmrs`). The instance is just a directory: `instance.env`, one env file per
service (`openmrs.env` holds the two values you set; the others are empty, so the services'
defaults apply), and `tools`, the tools directory this instance runs. Every `pihx t1 ...` runs from
that directory, whichever copy of the tools you typed it with ([An instance's files](env.md)).

```bash
PIHX_DEBUG=1 pihx t1 start
pihx t1 wait
```

- `start` creates the instance's volumes (`Created volume t1_db-data`, ...) and says *the database
  has no tables: OpenMRS will create them*. `PIHX_DEBUG=1` prints every `docker` command it runs.
- `wait` waits until every service with a healthcheck is ready, then prints *t1 is ready*. A first
  start with a full config import can take a while, and `wait` can go quiet during long steps:
  `pihx t1 logs openmrs` in another terminal shows what OpenMRS is doing. Then log in at
  `http://localhost:8080/openmrs`.

Stop and start it again:

```bash
pihx t1 stop && pihx t1 start
```

This time it says *the database has tables: OpenMRS won't create them*. pihx decides this from the
database itself before every start, and anything it can't confirm counts as "don't create", so a
restored or existing database is never re-created.

## 3. Looking around

```bash
pihx t1 status                 # the containers, and what holds the instance's lock
pihx t1 logs                   # follow every service's log (Ctrl-C to stop); logs openmrs for one
pihx t1 config                 # the instance's settings, secrets masked
pihx t1 compose ps
pihx t1 compose config openmrs # exactly what runs for a service: image, env, mounts, ports
pihx t1 compose exec openmrs-db sh
pihx t1 summary                # a fingerprint of the data: tables, row counts, data directory
pihx t1 openmrs-db             # a service's own commands (e.g. reset-accounts)
```

`pihx t1 compose ...` is `docker compose` with the instance's project, files and settings filled
in, limited to commands that look (`config`, `ps`, `logs`, `exec`, ...). `compose config` prints
passwords unmasked: don't paste it anywhere.

## 4. What it won't let you do

pihx is built so that the easy mistake doesn't lose data. Try these; each is refused or harmless:

```bash
pihx t1 compose down                 # refused, with the pihx command to use instead
pihx t1 run-service openmrs-db sh    # refused: run-service is for jobs (use compose exec)
docker compose -p t1 down -v         # removes the containers, but not the data
docker volume ls | grep t1_          # the volumes are still there
pihx t1 start && pihx t1 wait        # "the database has tables": nothing lost
```

The volumes are *external*: pihx creates them and only `destroy` removes them, after archiving
them, so the `down -v` you type every day elsewhere can't delete an instance's database
([Volumes](instances.md#volumes)). Commands that change an instance also take a lock, so two can't
run at once ([One command at a time](instances.md#one-command-at-a-time)), and everything pihx
writes on your machine belongs to you, not root.

## 5. Back up, and restore into a second instance

Back up t1 with `openmrs-utils` ([Utilities](utilities.md)):

```bash
mkdir ~/rt
MYSQL_PASSWORD=openmrs openmrs-utils backup-mysqldump --container=t1-openmrs-db \
  --output=$HOME/rt/openmrs-db.sql.gz
openmrs-utils backup-openmrs-data-directory --volume=t1_openmrs-data \
  --output=$HOME/rt/openmrs.tar.gz --allow-running --exclude-distribution-artifacts
pihx t1 summary --output=$HOME/before.txt
pihx t1 stop
```

- `openmrs-utils` works on containers and volumes by name (`t1-openmrs-db`, `t1_openmrs-data`;
  `pihx t1 compose ps` and `docker volume ls` show them), and `backup-mysqldump` needs the
  database's root password in `MYSQL_PASSWORD` (`openmrs` unless you set `OPENMRS_DB_ROOT_PASSWORD`).
- `--exclude-distribution-artifacts` leaves out what the distribution image supplies again on every
  start (modules, configuration, frontend): without it the data directory backup is about a
  gigabyte, with it a megabyte or two.
- `--allow-running` backs up a running instance's data directory; OpenMRS keeps writing its log, so
  `openmrs.log`'s size can differ in the comparison below.
- Keep `before.txt` outside `~/rt`: `initialize` takes the directory's entries by name and refuses
  anything it doesn't recognise.

Restore into a new instance with the same settings, and compare before its first start:

```bash
OPENMRS_IMAGE_NAME=partnersinhealth/pihsl-emr \
OPENMRS_PIH_CONFIG=sierraLeone,sierraLeone-kgh,sierraLeone-kgh-ci \
openmrs-docker t2 create

pihx t2 initialize --from ~/rt
pihx t2 summary --output=$HOME/after.txt
diff ~/before.txt ~/after.txt       # no differences (but openmrs.log's size, above)
pihx t2 start && pihx t2 wait       # "the database has tables"
```

`initialize` runs only on an instance that has never started, refuses if its volumes already
exist, and if anything fails removes only what it created ([Initializing an instance](restore.md)).

t1 was stopped first because both instances publish the same ports (8080, 3306). To run two at
once, give the second its own at `create`: `OPENMRS_HTTP_PORT=8081 OPENMRS_DB_PORT=3307`.

## 6. Starting from a seed

Each distro publishes a nightly seed image: a database and data directory already through OpenMRS's
first start. Filling an instance from it skips the long first start:

```bash
OPENMRS_IMAGE_NAME=partnersinhealth/pihsl-emr \
OPENMRS_PIH_CONFIG=sierraLeone,sierraLeone-kgh,sierraLeone-kgh-ci \
openmrs-docker t3 create
openmrs-docker t3 initialize --from-image partnersinhealth/pihsl-emr-seed-sierraleone
pihx t3 start && pihx t3 wait
```

A seed is `/seed/openmrs-db.sql.gz` and `/seed/openmrs.tar.gz` in an image, so you can build one
from your own backup too: `docker build -t local/my-seed -f <tools>/openmrs/seed/Dockerfile ~/rt`.

## 7. Developing a distro

`openmrs-docker` builds a distro from source and runs it ([Building a distro from
source](instances.md#building-a-distro-from-source-developers)):

```bash
OPENMRS_DISTRO_DIR=$HOME/code/github/pih/pihsl-emr \
OPENMRS_IMAGE_NAME=partnersinhealth/pihsl-emr \
OPENMRS_PIH_CONFIG=sierraLeone,sierraLeone-kgh,sierraLeone-kgh-ci \
openmrs-docker dev create

openmrs-docker dev start --build    # mvn package, build the image, start it
openmrs-docker dev update --dev     # run what you last built, with Java debugging on 1044
```

To try a change to the tools themselves on one instance only, point it at another copy:
`pihx <name> use-tools <dir>` ([Updating this tool, and pinning it](instances.md#updating-this-tool-and-pinning-it)).

## 8. Companion services

Services beyond OpenMRS (PETL and SQL Server, OpenHIM, the AdvaPACS gateway, ...) are added to an
instance by name ([Services](services.md)); each service's README lists its settings. PETL with
SQL Server on t2:

```bash
SQLSERVER_SA_PASSWORD=Sa-password-1 pihx t2 add-service sqlserver

PETL_IMAGE_NAME=partnersinhealth/sl-etl \
PETL_FULL_REFRESH_JOBS=refresh-ci-warehouse.yml \
PETL_MYSQL_PASSWORD=Petl-mysql-1 \
PETL_SQLSERVER_PASSWORD=Reporting-pw-1 \
pihx t2 add-service petl

pihx t2 start                       # starts sqlserver; petl is a job, so not yet
pihx t2 run-service --pull petl     # runs the jobs, then exits
pihx t2 logs petl
pihx t2 remove-service petl         # its volumes are kept
pihx t2 remove-service sqlserver
```

`add-service` writes the service's env file from the values in your shell that the service knows;
to change one later, edit `~/pihx/t2/<svc>.env` and `pihx t2 update`.

- SQL Server's passwords must be 8 or more characters, with three of upper case, lower case, digits
  and symbols, and must not contain the login's name (`petl`): `sqlserver-setup` checks this before
  changing anything.
- Use an ETL project's single-site CI job (`refresh-ci-warehouse.yml` for `sl-etl`). Production's
  multi-site jobs need datasources an instance doesn't have.

## 9. Archive and destroy

```bash
pihx t2 stop
pihx t2 archive        # ~/pihx/t2.archive-<time>/: a tar per volume, the env files, RESTORE.txt
pihx t2 destroy
```

`archive` is a full, cold copy of a stopped instance, with `RESTORE.txt` giving the commands that
bring it back. It includes the volumes of services removed since (t2's `sqlserver-data` and
`petl-data` above).

`destroy` is for development and test instances, and is deliberately slow: it lists everything it
will delete, asks you to type the instance's name, stops and archives the instance to
`~/pihx/<name>.destroyed-<time>/`, then asks you to type `delete`. Delete the archive yourself once
you're sure you don't need it ([Archive and destroy](instances.md#archive-and-destroy)).

Clean up the rest of the walk-through the same way (`pihx t1 destroy`, `pihx t3 destroy`), then
`pihx list` and `docker volume ls | grep -E '^local +t[123]_'` show nothing left.

## When something looks wrong

- **Port already allocated** at `start` or `initialize`: another instance (or anything else) has
  that port. Stop it, or give this instance its own ports (section 5).
- **SQL Server refuses a password:** see section 8.
- **`backup-mysqldump` fails to connect:** set `MYSQL_PASSWORD` to the database's root password
  (section 5).
- **`initialize` refuses its directory:** something other than the services' entries is in it (a
  summary file, `.DS_Store`). Move it out.
- **PETL fails on `${datasources.openmrs.<site>.host}`:** the job is a production multi-site one;
  use the ETL's CI job (section 8).
- **PIH Core stops after a restore, on a Liquibase error about `patientPastAppointments.sql`:** a
  known Bahmni appointments issue (TASKS-605), not the tools. `pihx <name> stop`, then `start` again.
- **A data directory backup is huge:** add `--exclude-distribution-artifacts` (section 5).
- **"is busy":** another command holds the instance's lock, and the message names it. Wait for it
  to finish.

## Further

- The [reference docs](../README.md#documentation): instances, their files, services, restores,
  utilities, CI workflows.
- Servers run the same tools from Puppet: `pihx <name> update` on each deploy.
