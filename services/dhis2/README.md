# dhis2

DHIS2, in the stock Tomcat image (`tomcat:<tag>`) for its Java, serving at `/dhis`. It requires
`dhis2-db`. The DHIS2 home (`dhis.conf`, `files/`, `apps/`) is in the `dhis2-data` volume, and the
release WARs are in `dhis2-wars`. Settings are in the instance's `dhis2.env`; defaults are in
[`env.defaults`](env.defaults).

| Variable | Default | |
|---|---|---|
| `DHIS2_VERSION` | none: must be set | a version in [`scripts/versions`](scripts/versions), e.g. `2.43.2.1` |
| `DHIS2_TOMCAT_TAG` | `10.1-jdk17-temurin-noble` | the Tomcat image's tag: the one `scripts/versions` gives for `DHIS2_VERSION`. The default is right for 2.42 and 2.43; an instance on an earlier version sets it too |
| `DHIS2_HTTP_PORT` | `8080` | the port published on the host; set it differently to run more than one instance at once |
| `DHIS2_BASE_URL` | `http://localhost:<DHIS2_HTTP_PORT>/dhis` | `server.base.url`: the address users reach DHIS2 at |
| `DHIS2_ENCRYPTION_PASSWORD` | empty (none) | `encryption.password`. An instance restored from another must have that one's, or DHIS2 can't read what it encrypted |
| `DHIS2_MEMORY_LIMIT`, `DHIS2_JAVA_OPTS` | `4g`, `-Xms1g -Xmx3g` | the container's memory limit, and Tomcat's Java options |
| `DHIS2_CONF_<key>` | none | any other `dhis.conf` setting ([below](#dhisconf)) |

The database's name, user and password come from `dhis2-db.env`: `dhis2` doesn't redefine them. `TZ`
comes from `instance.env`.

**Nothing in this repo changes the version an instance runs.** `DHIS2_VERSION` has no default, and
DHIS2's database migrations can't be undone, so the instance's own env (Puppet's `site.pp`) names the
version, and changing it is the only way to upgrade.

## Versions

[`scripts/versions`](scripts/versions) lists the versions this service runs, oldest first, one per line:
`<version> <tomcat tag> <WAR URL> <WAR SHA-256>`. Each is the final patch of its minor version and
an upgrade step, since DHIS2's migrations can't skip a minor version. The tag pins the Tomcat
and JDK the version needs, and the Ubuntu release, so `pull` brings Tomcat and Java patches but
never a new OS release: Tomcat 9 with JDK 8 up to 2.37, JDK 11 for 2.38 to 2.40 and JDK 17 for 2.41;
Tomcat 10.1 with JDK 17 for 2.42 and 2.43, which are Jakarta EE and never start in Tomcat 9.

To add a version: take its WAR URL and SHA-256 from
[DHIS2's release metadata](https://releases.dhis2.org/v1/versions/stable.json) (`.versions[] |
select(.name=="2.43") | .patchVersions[]`), and its JDK from the same file. Add the line in its place
in the list, oldest first, with the Tomcat tag for that JDK and servlet API (`<tomcat>-jdk<N>-temurin-<ubuntu
release>`: Tomcat 10.1 for a WAR with `jakarta.servlet-api` in `WEB-INF/lib`, 9 for one with
`javax`). The tag must exist on Docker Hub.

## Starting

Before every start, `dhis2-setup` runs [`scripts/setup.sh`](scripts/setup.sh) in the same Tomcat image,
and `dhis2` starts only if it succeeds. In order, it:

1. looks up `DHIS2_VERSION` in `scripts/versions`;
2. checks that `DHIS2_TOMCAT_TAG` is that version's tag;
3. refuses a downgrade: the DHIS2 home's `.dhis2-version` records the last version set up, and an
   earlier `DHIS2_VERSION` fails the start (e.g. a Puppet apply that puts an old version back after
   an upgrade);
4. makes sure `dhis2-wars` holds the version's WAR, `dhis2-<version>.war`. A WAR already there is
   kept if its SHA-256 matches; otherwise it's downloaded with `curl` and verified. **The host needs
   internet access at a start that needs a new WAR.**
5. writes `dhis.conf` (mode 600) into the DHIS2 home from the settings above, every time;
6. writes `.dhis2-version`.

Then `dhis2` runs Tomcat with our [`scripts/server.xml`](scripts/server.xml), which deploys the
version's WAR at `/dhis`. It has one HTTP connector with the query characters DHIS2's API uses
allowed, no AJP and no shutdown port. Its `RemoteIpValve` takes the scheme from `X-Forwarded-Proto`,
so behind a TLS-ending proxy DHIS2's redirects are https. The healthcheck
([`scripts/healthcheck.sh`](scripts/healthcheck.sh)) passes once `/dhis/` answers. It has two hours
to do so, for an upgrade's migrations.

DHIS2 runs as root, the stock Tomcat image's user.

### When a start fails

`pihx <name> start` names `dhis2-setup` and shows its last lines:

| Message | |
|---|---|
| `DHIS2_VERSION '<v>' isn't in services/dhis2/scripts/versions` | a version this repo doesn't list |
| `DHIS2 <v> runs on tomcat:<tag>; DHIS2_TOMCAT_TAG is <other>` | set `DHIS2_TOMCAT_TAG` as it says |
| `this instance last ran DHIS2 <old>; DHIS2_VERSION is <new>` | a downgrade: set `DHIS2_VERSION` back to `<old>` or later |
| `couldn't download <url>` | no internet access, or the release moved |
| `the download from <url> has SHA-256 ...` | the download isn't the release the list names: it's deleted, never used |

## dhis.conf

`dhis.conf` is written on every start, so edits to it are lost: change the instance's settings
instead. It has the database connection (`dhis2-db`, with `dhis2-db.env`'s name, user and password),
`connection.schema = update`, `server.base.url` and, if set, `encryption.password`. Each
`DHIS2_CONF_<key>` adds a line, `_` in `<key>` becoming `.` and `__` becoming `_`: for example,
`DHIS2_CONF_connection_pool_max__size=40` gives `connection.pool.max_size = 40`. Such a line comes
after the ones above, so it's the one DHIS2 reads. At `create`, the `DHIS2_CONF_*` in your shell go
into `dhis2.env` (the manifest's `capture-env`). Values are written as a Java properties file reads
them, with a backslash doubled.
