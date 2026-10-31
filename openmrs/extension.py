"""openmrs-docker, a pihx extension: pihx's command line, run by bin/openmrs-docker through pihx's
launcher, with OpenMRS development commands. It adds building a distribution from source (build,
start/update --build and --dev) and OpenMRS's defaults for create; initialize --from-image says what
a seed it can't restore probably is. Every other command is pihx's own."""

import os
import shutil
import sys

from pihx import cli, compose as compose_module, envfile, instance as instance_module, lock
from pihx.commands import CliError, initialize, instance_cmds, lifecycle
from pihx.commands.instance_cmds import tools_dir

USAGE = """
openmrs-docker is pihx with OpenMRS development commands: the commands above work as in pihx, and
it adds or changes:
  create [--services=a,b]    --services defaults to openmrs-db,openmrs; with openmrs,
                             OPENMRS_IMAGE_NAME must be set, and OPENMRS_DISTRO_DIR is kept in
                             openmrs.env
  add-service openmrs        The same checks, and OPENMRS_DISTRO_DIR kept in openmrs.env
  start [--build] [--dev]    --build: build the distribution in OPENMRS_DISTRO_DIR (Maven, on this
                             host) and its image first; --dev: mount the distribution built there
                             over the image's, and publish the Java debug port (OPENMRS_DEBUG_PORT)
  update [--build] [--dev]   The same, for update
  build                      Build the distribution and its OpenMRS image from OPENMRS_DISTRO_DIR
  initialize --from-image <image>
                             Also says when the image is probably an old-format seed
"""

DEFAULT_SERVICES = "openmrs-db,openmrs"
# start's and update's options for the dev and build overlays.
MODE_OPTIONS = ("--build", "--dev")
# The OpenMRS distribution's Maven project, which build, --build and --dev use. Kept in openmrs.env.
DISTRO_DIR = "OPENMRS_DISTRO_DIR"
# What a seed image pihx can't restore from probably is.
OLD_SEED_HINT = ("It's probably an old-format seed (dump.sql.gz, data.tar.gz): rebuild it from "
                 "openmrs/seed/Dockerfile, which holds files named after the services "
                 "(openmrs-db.sql.gz, openmrs.tar.gz)")


def _open(name):
    return instance_module.open(instance_module.home(), name, tools=tools_dir())


def _options(command, args, allowed=()):
    for arg in args:
        if arg not in allowed:
            raise CliError(f"unknown option '{arg}' for {command}", status=2)
    return set(args)


# --- create, add-service ---------------------------------------------------------------------------

def _openmrs_values():
    """For an instance gaining openmrs: checks OPENMRS_IMAGE_NAME, and returns the caller's
    OPENMRS_DISTRO_DIR (checked), or None."""
    if not os.environ.get("OPENMRS_IMAGE_NAME"):
        raise CliError("OPENMRS_IMAGE_NAME must be set to add the 'openmrs' service")
    distro_dir = os.environ.get(DISTRO_DIR) or None
    if distro_dir:
        if not os.path.isabs(distro_dir):
            raise CliError(f"{DISTRO_DIR} must be an absolute path, not '{distro_dir}'")
        try:
            envfile.format_line(DISTRO_DIR, distro_dir)
        except ValueError as e:
            raise CliError(str(e)) from None
    return distro_dir


def cmd_create(name, args):
    """pihx's create, with --services defaulting to openmrs-db,openmrs, and OpenMRS's values."""
    if instance_cmds.option(args, "services")[0] is None:
        args = [*args, f"--services={DEFAULT_SERVICES}"]
    selected = instance_cmds.check_create(name, args)
    distro_dir = _openmrs_values() if "openmrs" in {s.name for s in selected} else None
    instance_cmds.cmd_create(name, args)
    if distro_dir:
        instance_dir = instance_module.home() / name
        try:
            envfile.set_value(instance_dir / "openmrs.env", DISTRO_DIR, distro_dir)
        except BaseException:
            shutil.rmtree(instance_dir, ignore_errors=True)
            raise
    return 0


def cmd_add_service(name, args):
    """pihx's add-service, with OpenMRS's values when the service is openmrs."""
    inst, svc = instance_cmds.check_add_service(name, args)
    distro_dir = _openmrs_values() if svc.name == "openmrs" else None
    # One hold: the service is added with its value, or not at all.
    with lock.hold(inst, lock.wait_seconds(), command="add-service"):
        path = instance_cmds.add_service(inst, svc)
        if distro_dir:
            try:
                envfile.set_value(path, DISTRO_DIR, distro_dir)
            except BaseException:
                path.unlink()
                raise
    print(f"Added {svc.name} to {name}", file=sys.stderr)
    return 0


# --- start, update, build: the dev and build overlays ---------------------------------------------

def distro_dir(inst):
    """The instance's OPENMRS_DISTRO_DIR; an error if it has none."""
    value = inst.config().get(DISTRO_DIR, "")
    where = inst.dir / "openmrs.env"
    if not value:
        raise CliError(f"{DISTRO_DIR} must be set in {where} for this command")
    if not os.path.isabs(value):
        raise CliError(f"{DISTRO_DIR} in {where} must be an absolute path, not '{value}'")
    return value


def _compose(inst, build=False, dev=False):
    """The instance's Compose, with openmrs/modes/dev.yaml for --dev and build.yaml to build."""
    modes = inst.tools / "openmrs" / "modes"
    files = []
    if build or dev:
        if "openmrs" not in {s.name for s in inst.services}:
            raise CliError(f"{inst.name} has no openmrs service to build or mount a distribution "
                           "for")
        distro_dir(inst)
    if dev:
        files.append(modes / "dev.yaml")
    if build:
        files.append(modes / "build.yaml")
    return compose_module.Compose(inst, extra_files=files)


def _modes(args):
    """The extension's options in <args> (--build, --dev), and the rest, left for pihx's own command
    to refuse in its own words."""
    return ({a for a in args if a in MODE_OPTIONS}, [a for a in args if a not in MODE_OPTIONS])


def cmd_start(name, args):
    options, rest = _modes(args)
    if rest or not options:
        return lifecycle.cmd_start(name, rest)
    inst = _open(name)
    build = "--build" in options
    compose = _compose(inst, build=build, dev="--dev" in options)
    with lock.hold(inst, lock.wait_seconds(), command="start"):
        # The build, explicitly: for a service with both image: and build:, `up` pulls the named
        # tag if a registry has it, and only builds if that fails.
        lifecycle.start_stack(inst, compose, build=build)
    return 0


def cmd_update(name, args):
    options, rest = _modes(args)
    if rest or not options:
        return lifecycle.cmd_update(name, rest)
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
BUILD_OPTIONS = {"start": MODE_OPTIONS, "update": MODE_OPTIONS, "build": ()}


def cmd_distro_dir(name, args):
    """Internal, for bin/openmrs-docker, given the build command it is about to run (start, update or
    build, and its options): checks that command as far as it can before Maven builds the
    distribution on the host (its options, the openmrs service, OPENMRS_DISTRO_DIR, and that nothing
    holds the instance's lock, waiting PIHX_LOCK_WAIT for it as the command would), then prints the
    instance's OPENMRS_DISTRO_DIR."""
    if not args or args[0] not in BUILD_OPTIONS:
        raise CliError("usage: _distro-dir start|update|build [options]", status=2)
    command, options = args[0], args[1:]
    options = _options(command, options, BUILD_OPTIONS[command])
    inst = _open(name)
    _compose(inst, build=True, dev="--dev" in options)
    lock.check(inst, lock.wait_seconds())
    print(distro_dir(inst))
    return 0


# --- initialize -----------------------------------------------------------------------------------

def cmd_initialize(name, args):
    try:
        return initialize.cmd_initialize(name, args)
    except initialize.SeedError as e:
        raise CliError(f"{e}. {OLD_SEED_HINT}") from None


# The commands this extension adds or takes the place of; each takes (instance, args).
COMMANDS = {
    "create": cmd_create,
    "add-service": cmd_add_service,
    "start": cmd_start,
    "update": cmd_update,
    "build": cmd_build,
    "_distro-dir": cmd_distro_dir,
    "initialize": cmd_initialize,
}


def main(argv):
    return cli.main(argv, extension=sys.modules[__name__])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
