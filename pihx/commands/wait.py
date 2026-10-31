"""wait: until the instance's containers with a healthcheck are healthy."""

import os
import subprocess
import sys
import time

from pihx import compose as compose_module, instance as instance_module
from pihx.commands import CliError
from pihx.commands.instance_cmds import tools_dir

DEFAULT_TIMEOUT = 3600
# A container with this label fails the wait as soon as it reports unhealthy (e.g. a web
# application whose healthcheck only turns unhealthy once it has failed to start); the others, e.g. a
# database during a long import, keep waiting until the timeout.
LABEL = "pihx.wait"
FAIL_ON_UNHEALTHY = "fail-on-unhealthy"
POLL_SECONDS = 0.5


def timeout_seconds():
    value = os.environ.get("PIHX_WAIT_TIMEOUT", str(DEFAULT_TIMEOUT))
    if not value.isdigit() or int(value) == 0:
        raise CliError(f"PIHX_WAIT_TIMEOUT must be a positive number of seconds, not '{value}'")
    return int(value)


def _docker(compose, *args):
    return compose_module.docker(["docker", *args], env=compose.environment(),
                                 stdout=subprocess.PIPE, text=True)


def containers_to_wait_for(inst, compose):
    """(name, fail_on_unhealthy) for each running container of the instance with a healthcheck."""
    ids = []
    for status in ("running", "restarting"):
        ids += _docker(compose, "ps", "-q", "--filter", f"status={status}", "--filter",
                       f"label=com.docker.compose.project={compose.environment()['COMPOSE_PROJECT_NAME']}").stdout.split()
    if not ids:
        raise CliError(f"{inst.name} has no running containers (start it: "
                       f"'pihx {inst.name} start')")
    template = ('{{.Name}}\t{{index .Config.Labels "' + LABEL + '"}}\t'
                '{{with .Config.Healthcheck}}{{index .Test 0}}{{end}}')
    found = []
    for line in _docker(compose, "inspect", "-f", template, *ids).stdout.splitlines():
        name, label, test = (line.split("\t") + ["", ""])[:3]
        if test not in ("", "NONE"):
            found.append((name.lstrip("/"), label == FAIL_ON_UNHEALTHY))
    return sorted(found)


def cmd_wait(name, args):
    if args:
        raise CliError(f"unknown option '{args[0]}' for wait", status=2)
    inst = instance_module.open(instance_module.home(), name, tools=tools_dir())
    compose = compose_module.Compose(inst)
    timeout = timeout_seconds()
    targets = containers_to_wait_for(inst, compose)
    if not targets:
        print(f"{name} has no containers with a healthcheck to wait for.", file=sys.stderr)
        return 0
    script = inst.tools / "utils" / "wait-for-healthy.sh"
    # One wait per container at once, so one that fails (unhealthy, if labelled to) ends the wait while
    # the others are still starting. Logs of the fail-fast containers show why, from now on: a
    # container that has run a while has a long history, which isn't this startup.
    processes = {}
    logs = []
    try:
        for container, fail_fast in targets:
            processes[container] = subprocess.Popen(
                [str(script), f"--container={container}", f"--timeout={timeout}",
                 f"--fail-on-unhealthy={'true' if fail_fast else 'false'}"],
                env=compose.environment())
            if fail_fast:
                command = ["docker", "logs", "-f", "--since", str(int(time.time())), container]
                compose_module.echo(command)
                logs.append(subprocess.Popen(command, env=compose.environment(),
                                             stderr=subprocess.STDOUT))
        failed = None
        while processes and not failed:
            time.sleep(POLL_SECONDS)
            for container, process in list(processes.items()):
                code = process.poll()
                if code is None:
                    continue
                del processes[container]
                if code != 0:
                    failed = container
                    break
    finally:
        for process in [*processes.values(), *logs]:
            if process.poll() is None:
                process.terminate()
        for process in [*processes.values(), *logs]:
            process.wait()
    if failed:
        raise CliError(f"{failed} did not become ready -- see the output above, or "
                       f"'pihx {name} logs'")
    print(f"{name} is ready.")
    return 0
