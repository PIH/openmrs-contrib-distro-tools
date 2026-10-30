"""start, stop, restart, status, logs, pull, update and run-service."""

import contextlib
import json
import os
import re
import subprocess
import sys

from pihx import compose as compose_module, instance as instance_module, lock, script, volumes
from pihx.commands import CliError
from pihx.commands.instance_cmds import tools_dir
from pihx.instance import InstanceError

def exit_status(returncode):
    """A process's exit status as a shell reports it: 128+n when signal n killed it."""
    return 128 - returncode if returncode < 0 else returncode


def note(message):
    print(message, file=sys.stderr)


def _open(name):
    return instance_module.open(instance_module.home(), name, tools=tools_dir())


def _no_arguments(args, command):
    if args:
        raise CliError(f"unknown option '{args[0]}' for {command}", status=2)


def _docker(compose, *args, **kwargs):
    """docker <args> in the environment Compose runs in, output captured as text unless kwargs say
    otherwise."""
    kwargs.setdefault("capture_output", True)
    kwargs.setdefault("text", True)
    return compose_module.docker(["docker", *args], env=compose.environment(), **kwargs)


def _project_label(inst):
    return f"label=com.docker.compose.project={inst.name}"


# --- setup services, images -----------------------------------------------------------------------

def setup_services(inst):
    """The one-shot setup containers the instance's services declare (their manifests' `setup`)."""
    names = []
    for svc in sorted(inst.services, key=lambda s: s.name):
        names += [n for n in svc.manifest.setup if n not in names]
    return names


def check_setup_services(inst, compose):
    """Waits for each setup container to exit, and fails naming the first that didn't succeed.
    Compose itself only warns about an optional dependency that failed, and `up -d` doesn't wait."""
    for svc in setup_services(inst):
        ids = compose.run("ps", "-a", "-q", svc, stdout=subprocess.PIPE, text=True).stdout.split()
        if not ids:
            continue
        code = _docker(compose, "wait", ids[0]).stdout.strip()
        if not code.isdigit():
            raise CliError(f"couldn't wait for {svc} (docker wait gave '{code}'; see "
                           f"'pihx {inst.name} logs {svc}')")
        if code != "0":
            logs = _docker(compose, "logs", "--tail", "20", ids[0], capture_output=False,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            sys.stderr.write(logs.stdout)
            raise CliError(f"{svc} failed (exit {code}; above, or 'pihx {inst.name} logs {svc}')")


def instance_images(inst, compose):
    """The images the instance's containers, running or stopped, are made from (image IDs)."""
    ids = _docker(compose, "ps", "-aq", "--filter", _project_label(inst)).stdout.split()
    if not ids:
        return set()
    return set(_docker(compose, "inspect", "-f", "{{.Image}}", *ids).stdout.split())


def _inspect_image(compose, image_id, template):
    result = _docker(compose, "image", "inspect", "-f", template, image_id)
    return result.stdout.strip() if result.returncode == 0 else ""


def remove_replaced_images(inst, compose, before):
    """After containers were recreated: removes the images in <before> (instance_images from
    before) that none of the instance's containers is made from any more, so a deploy doesn't leave
    the image it replaced behind. Only images that can't be lost: one no tag points to any more (a
    pull of the same tag replaced it) or one a registry has (pulled), never a local build still
    tagged. docker image rm refuses an image any other container is made from (another instance on
    the same version), or that has more than one tag; either is left, quietly."""
    after = instance_images(inst, compose)
    for image_id in sorted(before - after):
        if _inspect_image(compose, image_id, '{{join .RepoTags " "}}') \
                and not _inspect_image(compose, image_id, '{{join .RepoDigests " "}}'):
            continue
        if _docker(compose, "image", "rm", image_id).returncode == 0:
            note(f"Removed the replaced image {image_id.removeprefix('sha256:')}")


VALUE_LINE = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=(.*)")


def start_values(inst, compose):
    """What the services' start-env scripts print (run with <compose>'s files and values), as
    KEY=value lines: values for this start's Compose only, never written anywhere. Each script sets
    only the variables its manifest entry declares (`sets`); any other is dropped with a warning,
    and pihx's own names (compose.RESERVED_NAMES) never. Every declared variable is passed, empty
    unless the script printed it, so a value in an env file can't stand in for it: a script that
    fails or prints a malformed line gives them all empty, with a warning, and Compose falls back to
    its compose file's default, which must be the safe one."""
    values = {}
    for svc in inst.services:
        for entry in svc.manifest.start_env:
            label = f"{svc.name}: {entry.script}"
            declared = [n for n in entry.sets if n not in compose_module.RESERVED_NAMES]
            given = dict.fromkeys(declared, "")
            result = script.run(inst, svc.dir / entry.script, service=svc, label=label,
                                extra_env=compose.extra_env, extra_files=compose.extra_files,
                                stdout=subprocess.PIPE, text=True)
            lines = [line for line in result.stdout.splitlines() if line.strip()]
            matches = [VALUE_LINE.fullmatch(line) for line in lines]
            if result.returncode != 0:
                note(f"warning: {label} failed (exit {result.returncode}); starting with "
                     f"{', '.join(declared)} empty")
            elif not all(matches):
                # Never the line: it may hold a secret.
                note(f"warning: {label} printed a malformed line (not KEY=value); starting with "
                     f"{', '.join(declared)} empty")
            else:
                for name, value in (m.groups() for m in matches):
                    if name in given:
                        given[name] = value
                    else:
                        note(f"warning: {label} printed {name}, which its manifest doesn't let it "
                             "set; ignored")
            values.update(given)
    return values


def with_start_values(inst, compose):
    """<compose> with the start-env scripts' values added to its extra_env."""
    return compose_module.Compose(inst, extra_files=compose.extra_files,
                                  extra_env={**compose.extra_env, **start_values(inst, compose)})


def start_stack(inst, compose, *up_options, build=False):
    """(With <build>, builds the images the compose files build, then) brings the instance up with
    the start-env scripts' values, then fails if a setup container did. Its missing volumes are
    created before anything starts (a start-env script may start a container)."""
    before = instance_images(inst, compose)
    if build:
        compose.run("build")
    volumes.ensure(compose)
    with_start_values(inst, compose).run("up", "-d", *up_options)
    check_setup_services(inst, compose)
    remove_replaced_images(inst, compose, before)


# --- commands -------------------------------------------------------------------------------------

def cmd_start(name, args):
    _no_arguments(args, "start")
    inst = _open(name)
    with lock.hold(inst, lock.wait_seconds(), command="start"):
        start_stack(inst, compose_module.Compose(inst))
    return 0


# Set (to the instance's name) in the environment of a service command that holds the lock.
LOCK_HELD = "PIHX_LOCK_HELD"


def cmd_start_locked(name, args):
    """Internal: `start` without taking the lock, for a service command that already holds it
    (e.g. openmrs-db's reset-accounts, which stops the instance and starts it again): the same
    start, with every service's setup checked."""
    _no_arguments(args, "_start")
    inst = _open(name)
    # The variable is only a hint: the lock must really be held (by the command that ran this).
    held = False
    if os.environ.get(LOCK_HELD) == name:
        try:
            lock.check(inst)
        except lock.LockError:
            held = True
    if not held:
        raise CliError("_start is for service commands that hold the lock; use 'start'", status=2)
    start_stack(inst, compose_module.Compose(inst))
    return 0


def cmd_update(name, args):
    _no_arguments(args, "update")
    inst = _open(name)
    compose = compose_module.Compose(inst)
    # One hold: a deploy mustn't be interleaved with another command between its pull and its up.
    with lock.hold(inst, lock.wait_seconds(), command="update"):
        update_stack(inst, compose)
    return 0


def update_stack(inst, compose, build=False):
    """Pulls, (with <build>, builds), brings the instance up (with the start-env scripts' values)
    removing the containers of services it no longer has, fails if a setup container did, and
    removes the images replaced. Its missing volumes are created before anything starts."""
    # Images before the pull, so the ones it replaces can go.
    before = instance_images(inst, compose)
    compose.run("pull")
    if build:
        compose.run("build")
    volumes.ensure(compose)
    with_start_values(inst, compose).run("up", "-d", "--remove-orphans")
    check_setup_services(inst, compose)
    remove_replaced_images(inst, compose, before)


def cmd_stop(name, args):
    _no_arguments(args, "stop")
    inst = _open(name)
    with lock.hold(inst, lock.wait_seconds(), command="stop"):
        # All profiles: a job's kept container (run-service) would otherwise outlive the network
        # it's attached to, and its next run fail.
        compose_module.Compose(inst).run("--profile", "*", "down", "--remove-orphans")
    return 0


def cmd_restart(name, args):
    _no_arguments(args, "restart")
    inst = _open(name)
    with lock.hold(inst, lock.wait_seconds(), command="restart"):
        compose_module.Compose(inst).run("restart")
    return 0


def cmd_pull(name, args):
    _no_arguments(args, "pull")
    inst = _open(name)
    with lock.hold(inst, lock.wait_seconds(), command="pull"):
        compose_module.Compose(inst).run("pull")
    return 0


def cmd_status(name, args):
    _no_arguments(args, "status")
    inst = _open(name)
    compose_module.Compose(inst).run("ps")
    holder = lock.holder(inst)
    if holder:
        print(f"Busy: {holder}")
    return 0


def cmd_logs(name, args):
    if len(args) > 1 or (args and args[0].startswith("-")):
        raise CliError(f"usage: pihx {name} logs [service]", status=2)
    inst = _open(name)
    # Ctrl-C is how following ends, not an error.
    try:
        result = compose_module.Compose(inst).run("logs", "-f", *args, check=False)
    except KeyboardInterrupt:
        return 0
    status = exit_status(result.returncode)
    if status not in (0, 130):
        raise CliError(f"docker compose logs failed (exit {status})")
    return 0


# compose's subcommands for inspecting an instance; the rest change it, which the managed commands do
# (under the lock, with the instance's start values).
COMPOSE_INSPECT = ("config", "ps", "images", "top", "port", "logs", "events", "ls", "version", "exec")
COMPOSE_INSTEAD = {
    "down": "stop (or destroy)", "stop": "stop (or destroy)",
    "up": "start (or update)", "start": "start (or update)", "create": "start (or update)",
    "restart": "restart", "pull": "pull", "run": "run-service",
    "rm": "remove-service or stop",
}


def _writes_a_file(arg):
    """Whether <arg> is config's -o/--output (alone, with its value, or in a cluster such as -qo)."""
    if arg.startswith("--"):
        return arg == "--output" or arg.startswith("--output=")
    return arg.startswith("-") and "o" in arg[1:]


def cmd_compose(name, args):
    """docker compose on the instance, as pihx runs it, with <args> after its options: only the
    inspecting subcommands, the first argument. No lock. Start-env values aren't computed (that
    could start containers), so their variables are empty, as when a script fails."""
    usage = f"usage: pihx {name} compose <{'|'.join(COMPOSE_INSPECT)}> [args...]"
    if not args:
        raise CliError(usage, status=2)
    subcommand = args[0]
    if subcommand.startswith("-"):
        raise CliError(f"compose takes the subcommand first, not '{subcommand}'; {usage}", status=2)
    if subcommand not in COMPOSE_INSPECT:
        if subcommand in COMPOSE_INSTEAD:
            raise CliError(f"compose {subcommand} would change '{name}' outside pihx's lock: use "
                           f"pihx {name} {COMPOSE_INSTEAD[subcommand]}", status=2)
        raise CliError(f"compose only inspects: '{subcommand}' isn't one of "
                       f"{', '.join(COMPOSE_INSPECT)}", status=2)
    if subcommand == "config" and any(_writes_a_file(a) for a in args[1:]):
        raise CliError("compose config only prints: -o/--output could overwrite one of the "
                       "instance's files (redirect its output instead)", status=2)
    inst = _open(name)
    declared = {n for svc in inst.services for entry in svc.manifest.start_env for n in entry.sets
                if n not in compose_module.RESERVED_NAMES}
    compose = compose_module.Compose(inst, extra_env=dict.fromkeys(sorted(declared), ""))
    return exit_status(compose.run(*args, check=False).returncode)


def _run_job(inst, compose, svc, command):
    """A job (a manifest with `job: true`, e.g. PETL) runs against the running instance: its setups
    run first as one-off containers with the current env, so it never runs on a failed one, and
    neither they nor it start, stop or recreate any of the instance's containers (--no-deps)."""
    for setup in setup_services(inst):
        result = compose.run("run", "--rm", "--no-deps", setup, check=False)
        if result.returncode != 0:
            raise CliError(f"{setup} failed (above), so {svc} didn't run -- is {inst.name} "
                           f"running ('pihx {inst.name} start')?")
    # A command of its own (e.g. a shell to look around) runs in a one-off container.
    if command:
        return exit_status(compose.run("run", "--rm", "--no-deps", svc, *command,
                                       check=False).returncode)
    # The job's own runs share one kept container, recreated only when its image or config changed
    # and otherwise started again: its log builds up across runs in Docker's log, as a running
    # service's does ('logs <svc>'), and docker inspect shows the last run's exit code and time.
    # start -a streams the run's output, forwards signals, and exits with the run's exit code.
    before = instance_images(inst, compose)
    compose.run("up", "--no-start", "--no-deps", svc)
    remove_replaced_images(inst, compose, before)
    ids = compose.run("ps", "-aq", svc, stdout=subprocess.PIPE, text=True).stdout.split()
    if not ids:
        raise CliError(f"no container for {svc}")
    return exit_status(_docker(compose, "start", "-a", ids[0], capture_output=False,
                               text=False).returncode)


def cmd_run_service(name, args):
    pull = bool(args) and args[0] == "--pull"
    rest = args[1:] if pull else args
    if not rest:
        raise CliError(f"usage: pihx {name} run-service [--pull] <service> [command...]", status=2)
    svc, command = rest[0], rest[1:]
    inst = _open(name)
    compose = compose_module.Compose(inst)
    # All profiles, and the instance's override files too: any container Compose knows.
    defined = json.loads(compose.run("--profile", "*", "config", "--format", "json",
                                     stdout=subprocess.PIPE, text=True).stdout or "{}")
    defined = defined.get("services") or {}
    if svc not in defined:
        raise InstanceError(f"{svc} not present on {name} (run 'add-service {svc}' first)")
    job = any(s.name == svc and s.manifest.job for s in inst.services)
    # Only one-shot containers: a job (its manifest's `job`) or one behind a profile, which no
    # start runs. A second openmrs or openmrs-db on the same volumes could corrupt them.
    runnable = sorted(n for n, spec in defined.items()
                      if (spec or {}).get("profiles") or any(s.name == n and s.manifest.job
                                                             for s in inst.services))
    if svc not in runnable:
        which = ", ".join(runnable) or "none here"
        raise CliError(f"{svc} runs with the instance, so run-service won't start another one: it "
                       f"runs only jobs and profiled services ({which}). For a command in its "
                       f"container: pihx {name} compose exec {svc} ...", status=2)
    if job:
        context = lock.hold(inst, lock.wait_seconds(), command="run-service")
    else:
        # Others, such as smoke tests, only check that nothing else holds the lock.
        lock.check(inst, lock.wait_seconds())
        context = contextlib.nullcontext()
    with context:
        return _run(inst, compose, svc, command, pull, job)


def _run(inst, compose, svc, command, pull, job):
    volumes.ensure(compose)
    # Named explicitly, so a profiled service's image is pulled too (a plain `pull` skips them).
    if pull:
        compose.run("pull", svc)
    # --no-deps: never starts or recreates what it depends on (start the instance first).
    if not job:
        return exit_status(compose.run("run", "--rm", "--no-deps", svc, *command,
                                       check=False).returncode)
    return _run_job(inst, compose, svc, command)
