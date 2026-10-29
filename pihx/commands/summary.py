"""summary: what each service of the instance says about its data, to compare a source with its
restored copy (summarize both and `diff` them).

Each service's summary.sh prints `[section]` lines and one fact per line, sorted, no secrets; the
sections come out in service order (a service after those it requires). openmrs-db's are the
fingerprint's (utils/fingerprint.sh), openmrs's the data directory's."""

import os
import subprocess
import sys

from pihx import instance as instance_module, script, services as services_module
from pihx.commands import CliError
from pihx.commands.instance_cmds import tools_dir

USAGE = "usage: pihx <instance> summary [--output=<file>] [--include-distribution-artifacts]"


def _parse(name, args):
    output, include = None, False
    args = list(args)
    while args:
        arg = args.pop(0)
        if arg.startswith("--output="):
            output = arg[len("--output="):]
        elif arg == "--output" and args:
            output = args.pop(0)
        elif arg == "--include-distribution-artifacts":
            include = True
        else:
            raise CliError(f"unknown option '{arg}' for summary\n{USAGE.replace('<instance>', name)}",
                           status=2)
    if output == "":
        raise CliError("--output needs a file", status=2)
    return output, include


def cmd_summary(name, args):
    output, include = _parse(name, args)
    inst = instance_module.open(instance_module.home(), name, tools=tools_dir())
    extra = {"PIHX_SUMMARY_INCLUDE_DISTRIBUTION_ARTIFACTS": "true"} if include else {}
    text = ""
    for svc in services_module.in_order(inst.services):
        if not svc.summary_script:
            continue
        result = script.run(inst, svc.summary_script, extra_env=extra, service=svc,
                            stdout=subprocess.PIPE, text=True, label=f"{svc.name}: summary.sh")
        if result.returncode != 0:
            raise CliError(f"{svc.name}: summary.sh failed (exit {result.returncode}); nothing "
                           "written")
        text += result.stdout
    if not text:
        print(f"None of {name}'s services has a summary.", file=sys.stderr)
    if output is None:
        sys.stdout.write(text)
        return 0
    # The launcher resolves the file and mounts its directory (PIHX_OUTPUT); otherwise it's the
    # caller's, if that's where pihx can write.
    target = os.environ.get("PIHX_OUTPUT") or os.path.join(os.environ.get("PIHX_CWD", ""), output)
    try:
        with open(target, "w") as f:
            f.write(text)
    except OSError as e:
        raise CliError(f"can't write {output}: {e.strerror}") from None
    print(f"Wrote {output}.", file=sys.stderr)
    return 0
