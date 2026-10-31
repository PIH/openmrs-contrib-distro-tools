"""destroy: removes a development or test instance -- its containers, volumes and directory -- but
only once a full archive of it (pihx/commands/archive.py) has been written and read back, and only
after two confirmations typed on standard input (no input, or anything else, stops it; there is no
--force).

  1. Lists the instance directory and every volume it would delete (those archive takes), with
     their sizes.
  2. Asks for the instance's name.
  3. Makes the archive directory, $PIHX_HOME/<name>.destroyed-<UTC time>/, and checks there's room
     for the volumes in it. Nothing has changed if either fails.
  4. Stops the instance (its containers removed, never its volumes).
  5. Archives it there, as archive does. If that fails, what it wrote is removed, and nothing else.
  6. Prints the archive's path and size, and asks for `delete`.
  7. Removes exactly the volumes listed in 1, then the instance directory (a real tools directory
     stays, as Puppet keeps one).

Anything that stops it before 7 deletes nothing, and says what state the instance is in."""

import os
import shutil

from pihx import compose as compose_module, instance as instance_module, lock, volumes
from pihx.commands import CliError, archive
from pihx.commands.archive import _docker, note, stderr_of as _stderr
from pihx.commands.instance_cmds import tools_dir
from pihx.instance import Instance, InstanceError

COMPOSE_PROJECT_LABEL = archive.COMPOSE_PROJECT_LABEL


def ask(prompt):
    """The line typed after <prompt>, or None at the end of input."""
    try:
        return input(prompt)
    except EOFError:
        print()
        return None


# --- stopping and removing ------------------------------------------------------------------------

def stop(inst, compose):
    """Removes the instance's containers (all profiles), never its volumes; by Compose's project
    label if Compose can't read the instance."""
    if inst.services and compose.run("--profile", "*", "down", "--remove-orphans",
                                     check=False).returncode == 0:
        return
    note("warning: 'docker compose down' failed -- removing this instance's containers by their "
         "Compose project label instead.")
    listing = _docker(compose, "ps", "-aq", "--filter",
                      f"label={COMPOSE_PROJECT_LABEL}={inst.name}")
    if listing.returncode != 0:
        raise CliError(f"couldn't list {inst.name}'s containers, so nothing was deleted: "
                       f"{_stderr(listing)}")
    ids = listing.stdout.split()
    if ids:
        removed = _docker(compose, "rm", "-f", *ids)
        if removed.returncode != 0:
            raise CliError(f"couldn't remove {inst.name}'s containers, so nothing was deleted: "
                           f"{_stderr(removed)}")


def remove_volumes(compose, names):
    """Removes <names>; an error naming those still there."""
    if not names:
        return
    result = _docker(compose, "volume", "rm", *names)
    left = sorted(set(names) & volumes.listed(compose))
    if left:
        raise CliError(f"couldn't remove the volume(s) {', '.join(left)}: {_stderr(result)}")


def remove_directory(inst, compose):
    """Removes the instance directory, reclaiming root-owned files first if need be (a one-off
    service, e.g. smoke tests via run-service, may have written some into a bind-mounted directory
    under it). A symlinked tools goes, never what it points to; a real tools directory
    (Puppet keeps it as a git checkout) stays, and so does the instance directory then."""
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
        # Never the kept tools directory: it is Puppet's, whose ownership stays as it is.
        chown = (["find", "/target", "-mindepth", "1", "-maxdepth", "1", "!", "-name", "tools",
                  "-exec", "chown", "-R", owner, "{}", "+"] if keep_tools
                 else ["chown", "-R", owner, "/target"])
        result = _docker(compose, "run", "--rm", "-v", f"{inst.dir}:/target", archive.alpine_image(inst),
                         *chown)
        if result.returncode != 0:
            raise InstanceError(f"couldn't remove {inst.dir}: {_stderr(result)}")
        try:
            remove()
        except OSError as e:
            raise InstanceError(f"couldn't remove {inst.dir}: {e}") from None
    if keep_tools:
        note(f"Kept {tools}: it is a directory of its own, not a symlink")
        return f"Removed instance {inst.name}'s files from {inst.dir}"
    return f"Removed instance directory {inst.dir}"


# --- the command ----------------------------------------------------------------------------------

def _open(name):
    try:
        return instance_module.open(instance_module.home(), name, tools=tools_dir())
    except InstanceError as e:
        # Still destroyable: its containers and volumes are found by their labels.
        error = instance_module.instance_name_error(name)
        instance_dir = instance_module.home() / name
        if error or not instance_dir.is_dir():
            raise
        note(f"warning: {e}")
        return Instance(name=name, dir=instance_dir, tools=tools_dir(), services=[])


def cmd_destroy(name, args):
    if "--force" in args:
        raise CliError("destroy has no --force: it always asks, twice, and archives the instance "
                       "before deleting anything", status=2)
    if args:
        raise CliError(f"unknown option '{args[0]}' for destroy", status=2)
    inst = _open(name)
    # PIHX_HOME may be /home, whose other directories are users' homes: only an instance's goes.
    if not (inst.dir / instance_module.INSTANCE_ENV).is_file():
        raise InstanceError(f"{inst.dir} has no {instance_module.INSTANCE_ENV}, so it isn't an "
                            "instance: not destroying it")
    compose = compose_module.Compose(inst)
    stamp, taken = archive.timestamp()
    dest = archive.Destination(inst.dir.parent / f"{name}.destroyed-{stamp}")
    folder = dest.path
    start_again = f"start it again with 'pihx {name} start'"
    with lock.hold(inst, lock.wait_seconds(), command="destroy"):
        image = archive.alpine_image(inst)
        names = archive.find_volumes(inst, compose)
        sizes = {v: archive.size_kb(compose, image, v) for v in names}
        width = max([len(v) for v in names] + [9])
        print(f"destroy is for development and test instances. It stops {name}, archives it to "
              f"{folder}/, and then deletes:")
        print(f"  directory {inst.dir}")
        for v in names:
            print(f"  volume    {v:<{width}}  {volumes.human(sizes[v])}")
        if not names:
            print("  (no volumes)")
        answer = ask(f"Type the instance's name ({name}) to stop it and archive it: ")
        if answer != name:
            raise CliError("destroy stopped: nothing was changed")
        try:
            dest.make()
        except CliError as e:
            raise CliError(f"{e}. destroy is for development and test instances, whose PIHX_HOME "
                           "is writable (a Puppet host's /home isn't)") from None
        try:
            archive.check_space(dest, sum(sizes.values()))
        except BaseException:
            dest.discard()
            raise
        try:
            stop(inst, compose)
            kb = archive.write(inst, compose, image, names, dest, taken, "destroy")
        except BaseException as e:
            dest.discard()
            if not isinstance(e, Exception):
                raise
            raise CliError(f"{e}. Nothing was deleted, and the incomplete archive is removed; "
                           f"{name} may be stopped: {start_again}.") from None
        print(f"Archived {name} to {folder}/ ({volumes.human(kb)}); {archive.RESTORE_FILE} there "
              "says how to recreate it.")
        answer = ask(f"Type delete to delete {name}'s volumes and directory: ")
        if answer != "delete":
            raise CliError(f"destroy stopped: nothing was deleted. {name} is stopped ("
                           f"{start_again}), and its archive is kept in {folder}/")
        try:
            remove_volumes(compose, names)
        except BaseException as e:
            if not isinstance(e, Exception):
                raise
            raise CliError(f"{e}. {inst.dir} is kept, so 'pihx {name} destroy' can be run again; "
                           f"the archive is in {folder}/") from None
        try:
            message = remove_directory(inst, compose)
        except InstanceError as e:
            raise InstanceError(f"{e}. Its volumes are removed; the archive is in {folder}/") \
                from None
    for v in names:
        print(f"Removed volume {v}")
    print(message)
    print(f"The archive is in {folder}/")
    return 0
