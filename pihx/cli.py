"""The command line: pihx <global command>, or pihx <instance> <command> [args...]."""

import os
import sys
import traceback

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
  use-tools <dir>            Run the instance from another tools directory
  start                      Bring the instance up and check its setup containers
  stop                       Remove its containers (not its volumes)
  restart                    Restart its containers
  status                     Show its containers, and what holds its lock
  logs [service]             Follow the logs
  compose <subcommand> [args...]
                             Inspect the instance with docker compose (config, ps, logs, exec, ...);
                             doesn't take the instance lock. Values a service's start script
                             decides are empty
  pull                       Pull its images
  update                     Pull, bring up (removing containers of removed services), and remove
                             the images replaced
  run-service [--pull] <service> [command...]
                             Run a job or profiled service once (a job holds the lock), never
                             its dependencies: start the instance first; exits with its exit code
  wait                       Wait until its containers with a healthcheck are healthy (a container
                             labelled pihx.wait=fail-on-unhealthy fails it at once; PIHX_WAIT_TIMEOUT,
                             default 3600 s)
  summary [--output=<file>] [--include-distribution-artifacts]
                             Summarize its data, to diff a source against its restored copy
  <service>                  List a service's commands
  <service> <command> [args...]
                             Run one of a service's commands (e.g. openmrs-db reset-accounts)
  initialize --from <dir> | --from-image <image>
                             Fill a new instance's volumes from a directory with an entry per service
                             (or an image's /seed directory), before its first start
  destroy [--force]          Remove its containers, volumes and directory (asks first)
  help                       Show this help
  version                    Show pihx's version and the tools directory it runs from
"""


def cmd_help(args, extension=None):
    print(USAGE, end="")
    if extension:
        print(extension.USAGE, end="")
    return 0


def cmd_version(args):
    tools = os.environ.get("PIHX_TOOLS", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    runtime = os.environ.get("PIHX_RUNTIME_IMAGE")
    print(f"pihx {__version__}")
    print(f"tools: {tools}")
    if runtime:
        print(f"runtime: {runtime}")
    return 0


# help, there or after an instance, is dispatch's: an extension adds to it.
GLOBAL_COMMANDS = {"version": cmd_version, "list": instance_cmds.cmd_list}

# Commands on an instance; each takes (instance, args). version reports the tools directory the instance
# runs (the launcher has already handed off to it).
INSTANCE_COMMANDS = {
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
    "compose": lifecycle.cmd_compose,
    "pull": lifecycle.cmd_pull,
    "update": lifecycle.cmd_update,
    "run-service": lifecycle.cmd_run_service,
    "initialize": initialize.cmd_initialize,
    "destroy": lifecycle.cmd_destroy,
    "wait": wait.cmd_wait,
    "summary": summary.cmd_summary,
}


def dispatch(argv, extension=None):
    """Runs a command line. <extension>: an extension's module (e.g. openmrs.extension), whose
    COMMANDS add instance commands or take the place of pihx's, and whose USAGE help adds."""
    commands = {**INSTANCE_COMMANDS, **(extension.COMMANDS if extension else {})}
    if not argv:
        sys.stderr.write(USAGE + (extension.USAGE if extension else ""))
        raise CliError("no command given", status=2)
    first, rest = argv[0], argv[1:]
    if first == "help":
        return cmd_help(rest, extension)
    if first in GLOBAL_COMMANDS:
        return GLOBAL_COMMANDS[first](rest)
    error = instance_name_error(first)
    if error:
        raise CliError(error, status=2)
    if not rest:
        raise CliError(f"no command given for instance '{first}' (see 'pihx help')", status=2)
    command = rest[0]
    if command == "help":
        return cmd_help(rest[1:], extension)
    if command not in commands:
        if service_cmds.is_service(command):
            return service_cmds.cmd_service(first, command, rest[1:])
        raise CliError(f"unknown command '{command}' (see 'pihx help')", status=2)
    return commands[command](first, rest[1:])


def main(argv, extension=None):
    """Runs a command line (dispatch, with <extension> if given), reporting an error as an `error:`
    line and an exit status. Ctrl-C exits 130; anything unexpected is one `error:` line too, with
    its traceback under PIHX_DEBUG=1."""
    try:
        # The launcher mounts the caller's Docker config here; set up before any docker command.
        docker_config = os.environ.get("PIHX_DOCKER_CONFIG")
        if docker_config:
            runtime.install_docker_config(docker_config, os.environ["HOME"])
        return dispatch(argv, extension)
    except (CliError, runtime.SetupError, InstanceError, ServiceError, ComposeError, LockError,
            OSError) as e:
        print(f"error: {e}", file=sys.stderr)
        return getattr(e, "status", 1)
    except KeyboardInterrupt:
        print("error: interrupted", file=sys.stderr)
        return 130
    except Exception as e:
        if os.environ.get("PIHX_DEBUG") == "1":
            traceback.print_exc()
        print(f"error: {str(e) or type(e).__name__} (PIHX_DEBUG=1 shows where)", file=sys.stderr)
        return 1
