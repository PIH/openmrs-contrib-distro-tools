"""start, stop, restart, status, logs, pull, update, run-service and destroy."""

import contextlib
import os
import re
import shutil
import subprocess
import sys

from pihx import compose as compose_module, instance as instance_module, lock
from pihx.commands import CliError
from pihx.commands.instance_cmds import tools_dir
from pihx.instance import Instance, InstanceError

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
    return subprocess.run(["docker", *args], env=compose.environment(), **kwargs)


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


def start_stack(inst, compose, *up_options):
    """Brings the instance up, then fails if a setup container did."""
    before = instance_images(inst, compose)
    compose.run("up", "-d", *up_options)
    check_setup_services(inst, compose)
    remove_replaced_images(inst, compose, before)


# --- commands -------------------------------------------------------------------------------------

def cmd_start(name, args):
    _no_arguments(args, "start")
    inst = _open(name)
    with lock.hold(inst, lock.wait_seconds(), command="start"):
        start_stack(inst, compose_module.Compose(inst))
    return 0


def cmd_update(name, args):
    _no_arguments(args, "update")
    inst = _open(name)
    compose = compose_module.Compose(inst)
    # One hold: a deploy mustn't be interleaved with another command between its pull and its up.
    with lock.hold(inst, lock.wait_seconds(), command="update"):
        # Images before the pull, so the ones it replaces can go.
        before = instance_images(inst, compose)
        compose.run("pull")
        compose.run("up", "-d", "--remove-orphans")
        check_setup_services(inst, compose)
        remove_replaced_images(inst, compose, before)
    return 0


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
    compose_module.Compose(inst).run("logs", "-f", *args)
    return 0


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
    defined = compose.run("--profile", "*", "config", "--services", stdout=subprocess.PIPE,
                          text=True).stdout.split()
    if svc not in defined:
        raise InstanceError(f"{svc} not present on {name} (run 'add-service {svc}' first)")
    job = any(s.name == svc and s.manifest.job for s in inst.services)
    if job:
        context = lock.hold(inst, lock.wait_seconds(), command="run-service")
    else:
        # Others, such as smoke tests, only check that nothing else holds the lock.
        lock.check(inst, lock.wait_seconds())
        context = contextlib.nullcontext()
    with context:
        return _run(inst, compose, svc, command, pull, job)


def _run(inst, compose, svc, command, pull, job):
    # Named explicitly, so a profiled service's image is pulled too (a plain `pull` skips them).
    if pull:
        compose.run("pull", svc)
    if not job:
        return exit_status(compose.run("run", "--rm", svc, *command, check=False).returncode)
    return _run_job(inst, compose, svc, command)


# --- destroy --------------------------------------------------------------------------------------

def _alpine_image(inst):
    """The tools' ALPINE_IMAGE (utils/lib/images.sh), the one image for chores like this."""
    text = (inst.tools / "utils" / "lib" / "images.sh").read_text()
    found = re.search(r"^ALPINE_IMAGE=(\S+)", text, re.MULTILINE)
    if not found:
        raise InstanceError(f"no ALPINE_IMAGE in {inst.tools / 'utils' / 'lib' / 'images.sh'}")
    return found.group(1)


def _remove_directory(inst, compose):
    """Removes the instance directory, reclaiming root-owned files first if need be (a one-off
    service, e.g. smoke tests via run-service, may have written some into a bind-mounted directory
    under it). Its tools link goes, never what it points to; a tools directory (Puppet's
    checkout) stays, and so does the directory then."""
    if inst.dir.is_symlink():
        # Only the link: what it points to isn't this instance's to remove.
        inst.dir.unlink()
        return f"Removed instance directory {inst.dir}"
    tools = inst.dir / "tools"
    keep_tools = tools.is_dir() and not tools.is_symlink()

    def remove():
        for entry in inst.dir.iterdir():
            if keep_tools and entry == tools:
                continue
            if entry.is_dir() and not entry.is_symlink():
                shutil.rmtree(entry)
            else:
                entry.unlink()
        if not keep_tools:
            inst.dir.rmdir()

    try:
        remove()
    except OSError:
        owner = f"{os.getuid()}:{os.getgid()}"
        # Never the kept tools directory: it is Puppet's checkout, whose ownership stays as it is.
        chown = (["find", "/target", "-mindepth", "1", "-maxdepth", "1", "!", "-name", "tools",
                  "-exec", "chown", "-R", owner, "{}", "+"] if keep_tools
                 else ["chown", "-R", owner, "/target"])
        result = _docker(compose, "run", "--rm", "-v", f"{inst.dir}:/target", _alpine_image(inst),
                         *chown)
        if result.returncode != 0:
            raise InstanceError(f"couldn't remove {inst.dir}: {result.stderr.strip()}")
        try:
            remove()
        except OSError as e:
            raise InstanceError(f"couldn't remove {inst.dir}: {e}") from None
    if keep_tools:
        note(f"Kept {tools}: it is a checkout, not a link")
        return f"Removed instance {inst.name}'s files from {inst.dir}"
    return f"Removed instance directory {inst.dir}"


def cmd_destroy(name, args):
    unknown = [a for a in args if a != "--force"]
    _no_arguments(unknown, "destroy")
    force = bool(args)
    try:
        inst = _open(name)
    except InstanceError as e:
        # Still destroyable: its containers and volumes are found by their Compose project label.
        error = instance_module.instance_name_error(name)
        instance_dir = instance_module.home() / name
        if error or not instance_dir.is_dir():
            raise
        note(f"warning: {e}")
        inst = Instance(name=name, dir=instance_dir, tools=tools_dir(), services=[])
    if not force:
        print(f"This will stop the stack, delete all volumes, and remove {inst.dir}.")
        try:
            answer = input("Are you sure? [y/N] ")
        except EOFError:
            answer = ""
        if not re.fullmatch(r"[Yy]", answer):
            return 0
    compose = compose_module.Compose(inst)
    with lock.hold(inst, lock.wait_seconds(), command="destroy"):
        # An instance whose files don't interpolate (e.g. a required variable unset) must still be
        # destroyable, so its containers and volumes are then found by Compose's project label. All
        # profiles, so a profiled service's volumes (petl-data) and kept container go too.
        if not inst.services or compose.run("--profile", "*", "down", "-v", "--remove-orphans",
                                            check=False).returncode != 0:
            note("warning: 'docker compose down' failed -- removing this instance's containers and "
                 "volumes by their Compose project label instead.")
            label = _project_label(inst)
            ids = _docker(compose, "ps", "-aq", "--filter", label).stdout.split()
            if ids:
                _docker(compose, "rm", "-f", *ids)
            volumes = _docker(compose, "volume", "ls", "-q", "--filter", label).stdout.split()
            if volumes:
                _docker(compose, "volume", "rm", *volumes)
        # Volumes only restore overlays declare (initialize's staging): `down -v` doesn't know them.
        restore_volumes = sorted({v for s in inst.services for v in s.restore_volumes()})
        if restore_volumes:
            _docker(compose, "volume", "rm", *(f"{inst.name}_{v}" for v in restore_volumes))
        message = _remove_directory(inst, compose)
    print(message)
    return 0
