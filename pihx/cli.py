"""The command line: pihx <global command>, or pihx <instance> <command> [args...]."""

import os
import sys

from pihx import __version__, runtime
from pihx.instance import RESERVED_NAMES, instance_name_error

USAGE = """\
Usage:
  pihx list | help | version
  pihx <instance> <command> [args...]

Instance names: lowercase letters, digits, '-' and '_', starting with a letter or digit; not a
global command's name.

Commands:
  help       Show this help
  version    Show pihx's version and the checkout it runs from
"""


class CliError(Exception):
    """An error to report as `error: <message>` with a non-zero status."""

    def __init__(self, message, status=1):
        super().__init__(message)
        self.status = status


def cmd_help(args):
    print(USAGE, end="")
    return 0


def cmd_version(args):
    tools = os.environ.get("PIHX_TOOLS", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    runtime = os.environ.get("PIHX_RUNTIME_IMAGE")
    print(f"pihx {__version__}")
    print(f"tools: {tools}")
    if runtime:
        print(f"runtime: {runtime}")
    return 0


GLOBAL_COMMANDS = {"help": cmd_help, "version": cmd_version}

# Commands on an instance; each takes (instance, args). version reports the checkout the instance
# runs (the launcher has already handed off to it).
INSTANCE_COMMANDS = {
    "help": lambda instance, args: cmd_help(args),
    "version": lambda instance, args: cmd_version(args),
}


def dispatch(argv):
    if not argv:
        sys.stderr.write(USAGE)
        raise CliError("no command given", status=2)
    first, rest = argv[0], argv[1:]
    if first in GLOBAL_COMMANDS:
        return GLOBAL_COMMANDS[first](rest)
    if first in RESERVED_NAMES:
        raise CliError(f"'{first}' isn't implemented yet")
    error = instance_name_error(first)
    if error:
        raise CliError(error, status=2)
    if not rest:
        raise CliError(f"no command given for instance '{first}' (see 'pihx help')", status=2)
    command = rest[0]
    if command not in INSTANCE_COMMANDS:
        raise CliError(f"unknown command '{command}' (see 'pihx help')", status=2)
    return INSTANCE_COMMANDS[command](first, rest[1:])


def main(argv):
    try:
        # The launcher mounts the caller's Docker config here; set up before any docker command.
        docker_config = os.environ.get("PIHX_DOCKER_CONFIG")
        if docker_config:
            runtime.install_docker_config(docker_config, os.environ["HOME"])
        return dispatch(argv)
    except (CliError, runtime.SetupError) as e:
        print(f"error: {e}", file=sys.stderr)
        return getattr(e, "status", 1)
