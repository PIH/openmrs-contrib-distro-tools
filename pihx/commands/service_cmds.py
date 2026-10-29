"""pihx <instance> <service> [<command> [args...]]: a service's own commands, the executable files
in its commands/ directory. They run like its scripts (pihx/script.py), holding the instance lock
unless the file's first lines contain `# pihx: no-lock` (for one that only reads). A command's
description is the first comment line after its shebang."""

import contextlib

from pihx import instance as instance_module, lock, script, services as services_module
from pihx.commands import CliError
from pihx.commands.instance_cmds import tools_dir
from pihx.commands import lifecycle
from pihx.commands.lifecycle import exit_status

NO_LOCK = "# pihx: no-lock"
HEADER_LINES = 10


def _header(path):
    with open(path, errors="replace") as f:
        return [line.rstrip("\n") for _, line in zip(range(HEADER_LINES), f)]


def wants_lock(path):
    return NO_LOCK not in [line.strip() for line in _header(path)]


def description(path):
    for line in _header(path)[1:]:
        if line.startswith("#") and not line.startswith(NO_LOCK):
            return line.lstrip("# ").strip()
    return ""


def is_service(name):
    return bool(services_module.NAME.fullmatch(name)) and (tools_dir() / "services" / name).is_dir()


def cmd_service(name, service, args):
    inst = instance_module.open(instance_module.home(), name, tools=tools_dir())
    svc = next((s for s in inst.services if s.name == service), None)
    if svc is None:
        raise CliError(f"{name} doesn't have the service '{service}' (add it: "
                       f"'pihx {name} add-service {service}')")
    if not args:
        if not svc.commands:
            print(f"{service} has no commands.")
        else:
            print(f"Commands of {service}:")
            for command, path in svc.commands.items():
                print(f"  {command:<20} {description(path)}".rstrip())
        return 0
    command, rest = args[0], args[1:]
    if command not in svc.commands:
        raise CliError(f"{service} has no command '{command}' (see 'pihx {name} {service}')",
                       status=2)
    path = svc.commands[command]
    locked = wants_lock(path)
    holding = (lock.hold(inst, lock.wait_seconds(), command=f"{service} {command}")
               if locked else contextlib.nullcontext())
    # Tells a pihx the command runs (e.g. `_start`) that this process holds the lock.
    extra = {lifecycle.LOCK_HELD: inst.name} if locked else None
    with holding:
        result = script.run(inst, path, rest, extra_env=extra, service=svc,
                            label=f"{service} {command}")
    return exit_status(result.returncode)
