"""The command line: pihx <global command>, or pihx <instance> <command> [args...]."""

import os
import sys

from pihx import __version__, runtime
from pihx.commands import (CliError, initialize, instance_cmds, lifecycle, service_cmds, summary,
                           wait)
from pihx.compose import ComposeError
from pihx.instance import InstanceError, instance_name_error
from pihx.lock import LockError
from pihx.services import ServiceError

USAGE = """\
Usage:
  pihx list | help | version
  pihx <instance> <command> [args...]

Instance names: lowercase letters, digits, '-' and '_', starting with a letter or digit; not a
global command's name.

Commands:
  list                       Show the instances
  create --services=a,b      Make the instance (one env file per service, from your environment)
  config [--show-secrets]    Print the merged values, secrets masked
  add-service <service>      Add a service to the instance
  remove-service <service>   Remove a service's containers (not its volumes) and env file
  use-tools <path>           Run the instance from another distro-tools checkout
  start                      Bring the instance up and check its setup containers
  stop                       Remove its containers (not its volumes)
  restart                    Restart its containers
  status                     Show its containers, and what holds its lock
  logs [service]             Follow the logs
  pull                       Pull its images
  update                     Pull, bring up (removing containers of removed services), and remove
                             the images replaced
  run-service [--pull] <service> [command...]
                             Run a service once (a job holds the lock); exits with its exit code
  wait                       Wait until its containers with a healthcheck are healthy (an OpenMRS
                             that turns unhealthy fails it at once; PIHX_WAIT_TIMEOUT, default 3600 s)
  summary [--output=<file>] [--include-distribution-artifacts]
                             Summarize its data, to diff a source against its restored copy
  <service>                  List a service's commands
  <service> <command> [args...]
                             Run one of a service's commands (e.g. openmrs-db reset-accounts)
  initialize --from <folder> | --from-image <image>
                             Fill a new instance's volumes from a folder with an entry per service
                             (or an image's /seed folder), before its first start
  destroy [--force]          Remove its containers, volumes and directory (asks first)
  help                       Show this help
  version                    Show pihx's version and the checkout it runs from
"""


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


GLOBAL_COMMANDS = {"help": cmd_help, "version": cmd_version, "list": instance_cmds.cmd_list}

# Commands on an instance; each takes (instance, args). version reports the checkout the instance
# runs (the launcher has already handed off to it).
INSTANCE_COMMANDS = {
    "help": lambda instance, args: cmd_help(args),
    "version": lambda instance, args: cmd_version(args),
    "create": instance_cmds.cmd_create,
    "config": instance_cmds.cmd_config,
    "add-service": instance_cmds.cmd_add_service,
    "remove-service": instance_cmds.cmd_remove_service,
    "use-tools": instance_cmds.cmd_use_tools,
    "start": lifecycle.cmd_start,
    "_start": lifecycle.cmd_start_locked,
    "stop": lifecycle.cmd_stop,
    "restart": lifecycle.cmd_restart,
    "status": lifecycle.cmd_status,
    "logs": lifecycle.cmd_logs,
    "pull": lifecycle.cmd_pull,
    "update": lifecycle.cmd_update,
    "run-service": lifecycle.cmd_run_service,
    "initialize": initialize.cmd_initialize,
    "destroy": lifecycle.cmd_destroy,
    "wait": wait.cmd_wait,
    "summary": summary.cmd_summary,
}


def dispatch(argv):
    if not argv:
        sys.stderr.write(USAGE)
        raise CliError("no command given", status=2)
    first, rest = argv[0], argv[1:]
    if first in GLOBAL_COMMANDS:
        return GLOBAL_COMMANDS[first](rest)
    error = instance_name_error(first)
    if error:
        raise CliError(error, status=2)
    if not rest:
        raise CliError(f"no command given for instance '{first}' (see 'pihx help')", status=2)
    command = rest[0]
    if command not in INSTANCE_COMMANDS:
        if service_cmds.is_service(command):
            return service_cmds.cmd_service(first, command, rest[1:])
        raise CliError(f"unknown command '{command}' (see 'pihx help')", status=2)
    return INSTANCE_COMMANDS[command](first, rest[1:])


def main(argv, dispatcher=None):
    """Runs a command line (through <dispatcher>, default pihx's own dispatch: a front end such as
    openmrs-docker passes its own), reporting an error as an `error:` line and an exit status."""
    try:
        # The launcher mounts the caller's Docker config here; set up before any docker command.
        docker_config = os.environ.get("PIHX_DOCKER_CONFIG")
        if docker_config:
            runtime.install_docker_config(docker_config, os.environ["HOME"])
        return (dispatcher or dispatch)(argv)
    except (CliError, runtime.SetupError, InstanceError, ServiceError, ComposeError, LockError,
            OSError) as e:
        print(f"error: {e}", file=sys.stderr)
        return getattr(e, "status", 1)
