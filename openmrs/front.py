"""openmrs-docker, the OpenMRS front end on pihx: today's openmrs-docker command line, run by
bin/openmrs-docker through pihx's launcher. Most commands go straight to pihx's; the front end adds
OpenMRS's defaults (the openmrs-db and openmrs services), building and mounting a distribution from
source (build, --build, --dev), and the old names and inputs of the commands that changed:
fingerprint (pihx's summary), reset-openmrs-db-accounts (openmrs-db reset-accounts), and
initialize's RESTORE_* and SEED_IMAGE_* variables (a --from folder, or --from-image)."""

import os
import shutil
import sys
import tempfile
from pathlib import Path

from pihx import cli, compose as compose_module, envfile, instance as instance_module, lock
from pihx import services as services_module
from pihx.commands import (CliError, initialize, instance_cmds, lifecycle, service_cmds, summary,
                           wait)
from pihx.commands.instance_cmds import tools_dir

PROG = "openmrs-docker"

USAGE = f"""\
Usage:
  {PROG} create <name>        Create an instance (name: lowercase letters, digits, '-', '_')
  {PROG} list                 List the instances
  {PROG} <name> <command> [options]

Commands (for an existing instance):
  initialize              Fill a brand-new instance's volumes (see below)
  start [--build] [--dev] Start the stack
  update [--build] [--dev]
                          Pull its images and bring it up (recreates only what changed), then remove
                          the images replaced
  build                   Build the distribution and its OpenMRS image from DISTRO_SOURCE_DIR
  stop | restart | status | pull
  logs [service]          Follow the container logs; every service by default
  wait                    Wait until OpenMRS (and the instance's other containers) are ready
  add-service <svc>       Add a service (e.g. openmrs-smoke-tests)
  remove-service <svc>    Remove a service's containers and env file (its volumes are kept)
  run-service [--pull] <svc> [cmd...]
                          Run a service once (a job, such as petl, holds the instance lock)
  fingerprint [--data-dir] [--exclude-distribution-artifacts] [--output=<file>]
                          Summarize the database (and with --data-dir openmrs-data), to diff a
                          source against its restore (pihx's summary)
  reset-openmrs-db-accounts
                          Set the MySQL accounts and OpenMRS's connection settings to the passwords
                          in openmrs-db.env (pihx's openmrs-db reset-accounts)
  destroy [--force]       Remove the containers, volumes and instance directory

Options:
  --build   Build the distribution in DISTRO_SOURCE_DIR (Maven, on this host) and its image first
  --dev     Mount the distribution built in DISTRO_SOURCE_DIR over the image's, and publish the
            Java debug port (OPENMRS_DEBUG_PORT)
  --force   Don't ask first

create: SERVICES=<a,b,...> (default openmrs-db,openmrs) chooses the services. OPENMRS_IMAGE_NAME
must be set when they include openmrs. Each service's settings are taken from your environment
(see 'pihx help'), and DISTRO_SOURCE_DIR, SEED_IMAGE_NAME and SEED_IMAGE_TAG go in the instance's
instance.env.

initialize: from SEED_IMAGE_NAME[:SEED_IMAGE_TAG] (the instance's, else your environment's), or
from these, set on the command (never written anywhere):
  RESTORE_MYSQL_DUMP_PATH     db-data from a .sql or .sql.gz dump, or a .7z/.zip archive of one
  RESTORE_MYSQL_DATA_PATH     db-data from a MySQL data directory
  RESTORE_MYSQL_PERCONA_PATH  db-data from a Percona backup: a directory or a .7z/.zip/.tar.gz/
                              .tgz/.tar archive
  RESTORE_OPENMRS_DATA_PATH   openmrs-data from a directory or a .tar.gz/.tgz/.tar/.7z/.zip archive
  ARCHIVE_PASSWORD            the password of a .7z or .zip
  INITIALIZE_DB_TIMEOUT       seconds to wait for the restored database (default 3600)
A volume with no RESTORE_* source comes from the seed image, if there is one. initialize
--from <folder> | --from-image <image> works as pihx's.

Instances live in PIHX_HOME (default ~/pihx), with pihx's: 'pihx <name> <command>' works on them
too.
"""

DEFAULT_SERVICES = "openmrs-db,openmrs"
# Values only the front end uses, kept in the instance's instance.env when set at create: the
# distribution build, --build and --dev use, and the seed image initialize restores from. Their
# defaults are the front end's (DISTRO_SOURCE_DIR none, SEED_IMAGE_TAG latest).
FRONT_END_VALUES = ("DISTRO_SOURCE_DIR", "SEED_IMAGE_NAME", "SEED_IMAGE_TAG")
DEFAULT_SEED_IMAGE_TAG = "latest"

# initialize's RESTORE_* variables. bin/pihx resolves each path that exists on the host, mounts it
# at its own path, and passes it as PIHX_RESOLVED_<variable>.
DUMP, DATADIR, PERCONA = ("RESTORE_MYSQL_DUMP_PATH", "RESTORE_MYSQL_DATA_PATH",
                          "RESTORE_MYSQL_PERCONA_PATH")
DB_VARIABLES = (DUMP, DATADIR, PERCONA)
OPENMRS_DATA = "RESTORE_OPENMRS_DATA_PATH"
RESOLVED_PREFIX = "PIHX_RESOLVED_"
PERCONA_ARCHIVES = ("7z", "zip", "tar.gz", "tgz", "tar")
DATA_ARCHIVES = ("tar.gz", "tgz", "tar", "7z", "zip")


def _home():
    return instance_module.home()


def _open(name):
    return instance_module.open(_home(), name, tools=tools_dir())


def _options(command, args, allowed=()):
    for arg in args:
        if arg not in allowed:
            raise CliError(f"unknown option '{arg}' for {command}", status=2)
    return set(args)


def _service_names(inst):
    return {s.name for s in inst.services}


# --- create, list ---------------------------------------------------------------------------------

def cmd_create(name, args):
    if args:
        raise CliError(f"usage: {PROG} create <name>", status=2)
    services = os.environ.get("SERVICES") or DEFAULT_SERVICES
    if "openmrs" in services.split(",") and not os.environ.get("OPENMRS_IMAGE_NAME"):
        raise CliError("OPENMRS_IMAGE_NAME must be set to create an instance that includes the "
                       "'openmrs' service")
    values = {n: os.environ[n] for n in FRONT_END_VALUES if os.environ.get(n)}
    if "DISTRO_SOURCE_DIR" in values and not os.path.isabs(values["DISTRO_SOURCE_DIR"]):
        raise CliError(f"DISTRO_SOURCE_DIR must be an absolute path, not "
                       f"'{values['DISTRO_SOURCE_DIR']}'")
    for n, v in values.items():
        try:
            envfile.format_line(n, v)
        except ValueError as e:
            raise CliError(str(e)) from None
    instance_cmds.cmd_create(name, [f"--services={services}"])
    instance_dir = _home() / name
    try:
        for n, v in sorted(values.items()):
            envfile.set_value(instance_dir / instance_module.INSTANCE_ENV, n, v)
    except BaseException:
        shutil.rmtree(instance_dir, ignore_errors=True)
        raise
    return 0


def cmd_list(args):
    if args:
        raise CliError(f"usage: {PROG} list", status=2)
    for instance_dir, _ in instance_cmds.instances(_home()):
        print(instance_dir.name)
    return 0


# --- start, update, build: the dev and build overlays ---------------------------------------------

def distro_source_dir(inst):
    """The instance's DISTRO_SOURCE_DIR (in its instance.env); an error if it has none."""
    value = inst.config().get("DISTRO_SOURCE_DIR", "")
    where = inst.dir / instance_module.INSTANCE_ENV
    if not value:
        raise CliError(f"DISTRO_SOURCE_DIR must be set in {where} for this command")
    if not os.path.isabs(value):
        raise CliError(f"DISTRO_SOURCE_DIR in {where} must be an absolute path, not '{value}'")
    return value


def _compose(inst, build=False, dev=False):
    """The instance's Compose, with openmrs/modes/dev.yaml for --dev and build.yaml to build."""
    modes = inst.tools / "openmrs" / "modes"
    files = []
    if build or dev:
        distro_source_dir(inst)
        if "openmrs" not in _service_names(inst):
            raise CliError(f"{inst.name} has no openmrs service to build or mount a distribution "
                           "for")
    if dev:
        files.append(modes / "dev.yaml")
    if build:
        files.append(modes / "build.yaml")
    return compose_module.Compose(inst, extra_files=files)


def cmd_start(name, args):
    options = _options("start", args, ("--build", "--dev"))
    inst = _open(name)
    build = "--build" in options
    compose = _compose(inst, build=build, dev="--dev" in options)
    with lock.hold(inst, lock.wait_seconds(), command="start"):
        # The build, explicitly: for a service with both image: and build:, `up` pulls the named
        # tag if a registry has it, and only builds if that fails.
        lifecycle.start_stack(inst, compose, build=build)
    return 0


def cmd_update(name, args):
    options = _options("update", args, ("--build", "--dev"))
    inst = _open(name)
    build = "--build" in options
    compose = _compose(inst, build=build, dev="--dev" in options)
    with lock.hold(inst, lock.wait_seconds(), command="update"):
        lifecycle.update_stack(inst, compose, build=build)
    return 0


def cmd_build(name, args):
    _options("build", args)
    inst = _open(name)
    compose = _compose(inst, build=True)
    with lock.hold(inst, lock.wait_seconds(), command="build"):
        compose.run("build")
    return 0


# The options of the commands that build.
BUILD_OPTIONS = {"start": ("--build", "--dev"), "update": ("--build", "--dev"), "build": ()}


def cmd_distro_source_dir(name, args):
    """Internal, for bin/openmrs-docker, given the build command it is about to run (start, update or
    build, and its options): checks that command as far as it can before Maven builds the
    distribution on the host (its options, the openmrs service, DISTRO_SOURCE_DIR, and that nothing
    holds the instance's lock, waiting PIHX_LOCK_WAIT for it as the command would), then prints the
    instance's DISTRO_SOURCE_DIR."""
    if not args or args[0] not in BUILD_OPTIONS:
        raise CliError("usage: _distro-source-dir start|update|build [options]", status=2)
    command, options = args[0], args[1:]
    options = _options(command, options, BUILD_OPTIONS[command])
    inst = _open(name)
    _compose(inst, build=True, dev="--dev" in options)
    lock.check(inst, lock.wait_seconds())
    print(distro_source_dir(inst))
    return 0


# --- run-service, wait, fingerprint, reset-openmrs-db-accounts, sync ------------------------------

def caller_values(inst, svc):
    """The caller's values for the names <svc>'s env.defaults defines that the instance's own files
    don't set, for one run of it: openmrs-docker always took these from the shell (e.g. the
    smoke tests' SMOKE_TESTS_ADMIN_PASSWORD and output directories, set for the run)."""
    own = set()
    for path in (inst.dir / f"{svc.name}.env", inst.dir / instance_module.INSTANCE_ENV):
        if path.is_file():
            try:
                own |= set(envfile.parse(path.read_text()))
            except ValueError as e:
                raise CliError(f"{path}: {e}") from None
    return {n: os.environ[n] for n in svc.defaults if n in os.environ and n not in own}


def cmd_run_service(name, args):
    rest = args[1:] if args[:1] == ["--pull"] else args
    extra = {}
    if rest:
        inst = _open(name)
        svc = next((s for s in inst.services if s.name == rest[0]), None)
        if svc is not None:
            extra = caller_values(inst, svc)
    return lifecycle.cmd_run_service(name, args, extra_env=extra)


def cmd_wait(name, args):
    inst = _open(name)
    if "openmrs" not in _service_names(inst):
        return wait.cmd_wait(name, args)
    try:
        wait.cmd_wait(name, args)
    except CliError as e:
        if e.status == 2:
            raise
        raise CliError(f"OpenMRS did not become ready: {e}") from None
    print("OpenMRS is ready.")
    return 0


def cmd_fingerprint(name, args):
    data_dir = exclude = False
    output = None
    for arg in args:
        if arg == "--data-dir":
            data_dir = True
        elif arg == "--exclude-distribution-artifacts":
            exclude = True
        elif arg.startswith("--output=") and arg != "--output=":
            output = arg[len("--output="):]
        else:
            raise CliError(f"unknown option '{arg}' for fingerprint", status=2)
    inst = _open(name)
    by_name = {s.name: s for s in inst.services}
    if "openmrs-db" not in by_name:
        raise CliError(f"{name} has no openmrs-db service")
    services = [by_name["openmrs-db"]]
    if data_dir:
        if "openmrs" not in by_name:
            raise CliError(f"{name} has no openmrs service, whose openmrs-data --data-dir adds")
        services.append(by_name["openmrs"])
    summary.write(summary.summarize(inst, services, include=data_dir and not exclude), output)
    return 0


def cmd_reset_openmrs_db_accounts(name, args):
    _options("reset-openmrs-db-accounts", args)
    if "openmrs-db" not in _service_names(_open(name)):
        raise CliError(f"{name} has no openmrs-db service")
    return service_cmds.cmd_service(name, "openmrs-db", ["reset-accounts"])


def cmd_sync(name, args):
    _options("sync", args)
    inst = _open(name)
    print(f"sync is no longer needed: {name} uses the service files in its checkout "
          f"({inst.tools}) directly, so there's nothing to refresh.")
    return 0


# --- initialize -----------------------------------------------------------------------------------

def _resolved(variable):
    """<variable>'s path as the host has it (bin/pihx resolved and mounted it), or None if it
    doesn't exist there."""
    return os.environ.get(RESOLVED_PREFIX + variable) or None


def _extension(path, extensions):
    return next((e for e in extensions if path.endswith(f".{e}")), None)


def restore_entries():
    """The --from folder entries the RESTORE_* variables make: {entry name: host path}, named as the
    openmrs-db and openmrs services accept them. Refuses a path that doesn't exist or isn't of a
    kind the variable takes, and more than one database source."""
    entries = {}
    for variable in DB_VARIABLES + (OPENMRS_DATA,):
        value = os.environ.get(variable)
        if not value:
            continue
        path = _resolved(variable)
        if variable == DUMP:
            if not path or not os.path.isfile(path):
                raise CliError(f"no such file: {value}")
            archive = _extension(value, ("7z", "zip"))
            entry = (f"openmrs-db.sql.{archive}" if archive else
                     "openmrs-db.sql.gz" if value.endswith(".gz") else "openmrs-db.sql")
        elif variable == DATADIR:
            if not path or not os.path.isdir(path):
                raise CliError(f"no such directory: {value}")
            entry = "openmrs-db.datadir"
        else:
            if not path:
                raise CliError(f"no such file or directory: {value}")
            stem = "openmrs-db.percona" if variable == PERCONA else "openmrs"
            extensions = PERCONA_ARCHIVES if variable == PERCONA else DATA_ARCHIVES
            if os.path.isdir(path):
                entry = stem
            else:
                archive = _extension(value, extensions)
                if not archive:
                    raise CliError(f"{variable} must be a directory or a "
                                   f"{'/'.join('.' + e for e in extensions)} archive: {value}")
                entry = f"{stem}.{archive}"
        entries[entry] = path
    if sum(1 for v in DB_VARIABLES if os.environ.get(v)) > 1:
        raise CliError(_one_db_source())
    return entries


def _one_db_source():
    return ("set exactly one of RESTORE_MYSQL_DUMP_PATH, RESTORE_MYSQL_DATA_PATH, "
            "RESTORE_MYSQL_PERCONA_PATH, or SEED_IMAGE_NAME to initialize the mysql/db-data volume")


def _service_of(entry, tools):
    """The service whose restore names include <entry>, or None."""
    for svc in services_module.all(tools).values():
        for restore in svc.manifest.restore:
            if entry in (n.rstrip("/") for n in restore.names):
                return svc.name
    return None


def add_entries(folder, entries):
    """Links each entry into <folder>, by name, to its host path (the restore containers mount it
    through the link, which Docker resolves on the host); copies it where a link can't be made."""
    for entry, path in entries.items():
        target = Path(folder) / entry
        try:
            os.symlink(path, target)
        except OSError:
            if os.path.isdir(path):
                shutil.copytree(path, target, symlinks=True)
            else:
                shutil.copy2(path, target)


def seed_image(inst):
    """SEED_IMAGE_NAME:SEED_IMAGE_TAG, the instance's values, else the caller's; None if none."""
    config = inst.config()

    def value(name):
        return config.get(name) or os.environ.get(name) or ""

    name = value("SEED_IMAGE_NAME")
    if not name:
        return None
    return f"{name}:{value('SEED_IMAGE_TAG') or DEFAULT_SEED_IMAGE_TAG}"


def cmd_initialize(name, args):
    inst = _open(name)
    given = [v for v in DB_VARIABLES + (OPENMRS_DATA,) if os.environ.get(v)]
    if args:
        if given:
            raise CliError(f"initialize takes RESTORE_* variables or --from/--from-image, not "
                           f"both ({', '.join(given)} set)", status=2)
        return initialize.cmd_initialize(name, args)
    timeout = os.environ.get("INITIALIZE_DB_TIMEOUT")
    if timeout and not os.environ.get("PIHX_INITIALIZE_TIMEOUT"):
        os.environ["PIHX_INITIALIZE_TIMEOUT"] = timeout
    present = _service_names(inst)
    entries = restore_entries()
    covered = {"openmrs-db" if e.startswith("openmrs-db.") else "openmrs" for e in entries}
    for svc, variables in (("openmrs-db", DB_VARIABLES), ("openmrs", (OPENMRS_DATA,))):
        if svc in covered and svc not in present:
            raise CliError(f"{name} has no {svc} service to restore "
                           f"{' or '.join(v for v in variables if os.environ.get(v))} into")
    seed = seed_image(inst)
    if "openmrs-db" in present and "openmrs-db" not in covered and not seed:
        raise CliError(_one_db_source())
    from_seed = seed is not None and any(s in present and s not in covered
                                          for s in ("openmrs-db", "openmrs"))

    def adjust(folder):
        # The seed's entries for what the RESTORE_* variables restore, or for services the
        # instance lacks, go; anything else (e.g. an old seed's dump.sql.gz) is left for pihx to
        # refuse.
        for entry in os.listdir(folder):
            owner = _service_of(entry, inst.tools)
            if owner is not None and (owner in covered or owner not in present):
                path = Path(folder) / entry
                if path.is_dir() and not path.is_symlink():
                    shutil.rmtree(path)
                else:
                    path.unlink()
        add_entries(folder, entries)

    with lock.hold(inst, lock.wait_seconds(), command="initialize"):
        if from_seed:
            initialize.restore_image(inst, seed, adjust)
        else:
            # In the instance directory: PIHX_HOME (e.g. /home) may not be writable.
            folder = Path(tempfile.mkdtemp(prefix=".restore-", dir=inst.dir))
            try:
                add_entries(folder, entries)
                initialize.restore_folder(inst, folder, label="the RESTORE_* paths")
            finally:
                shutil.rmtree(folder, ignore_errors=True)
    print(f"Initialized {name}.")
    return 0


# --- the command line -----------------------------------------------------------------------------

def cmd_help(args):
    print(USAGE, end="")
    return 0


# Each takes (instance, args). The others are pihx's own.
COMMANDS = {
    "create": cmd_create,
    "start": cmd_start,
    "update": cmd_update,
    "build": cmd_build,
    "_distro-source-dir": cmd_distro_source_dir,
    "stop": lifecycle.cmd_stop,
    "restart": lifecycle.cmd_restart,
    "status": lifecycle.cmd_status,
    "logs": lifecycle.cmd_logs,
    "pull": lifecycle.cmd_pull,
    "destroy": lifecycle.cmd_destroy,
    "add-service": instance_cmds.cmd_add_service,
    "remove-service": instance_cmds.cmd_remove_service,
    "run-service": cmd_run_service,
    "wait": cmd_wait,
    "initialize": cmd_initialize,
    "fingerprint": cmd_fingerprint,
    "reset-openmrs-db-accounts": cmd_reset_openmrs_db_accounts,
    "sync": cmd_sync,
}


def dispatch(argv):
    if not argv:
        sys.stderr.write(USAGE)
        raise CliError("no command given", status=2)
    first, rest = argv[0], argv[1:]
    if first == "list":
        return cmd_list(rest)
    if first in ("help", "--help", "-h"):
        return cmd_help(rest)
    if first == "create":
        # bin/openmrs-docker puts the name first; this is `openmrs-docker create` with none.
        raise CliError(f"usage: {PROG} create <name>", status=2)
    error = instance_module.instance_name_error(first)
    if error:
        raise CliError(error, status=2)
    if not rest:
        raise CliError(f"no command given for instance '{first}' (run '{PROG} help')", status=2)
    command, args = rest[0], rest[1:]
    if command not in COMMANDS:
        raise CliError(f"unknown command '{command}' (run '{PROG} help')", status=2)
    if command != "create":
        instance_dir = _home() / first
        if not instance_dir.is_dir():
            raise CliError(f"no instance found at {instance_dir} (run '{PROG} create {first}' "
                           "first)", status=2)
    return COMMANDS[command](first, args)


def main(argv):
    return cli.main(argv, dispatcher=dispatch)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
