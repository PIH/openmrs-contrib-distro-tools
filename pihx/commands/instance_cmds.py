"""create, list, config, add-service, remove-service and use-tools."""

import os
import re
import shutil
import sys
from pathlib import Path

from pihx import compose as compose_module, envfile, instance as instance_module, lock
from pihx import services as services_module
from pihx.commands import CliError
from pihx.instance import Instance, InstanceError

# Compose files refer to values as ${NAME...} or $NAME; `$$` is a literal dollar.
REFERENCE = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)")
# Names pihx sets itself (see Compose.env): never an instance's values, whatever the caller has.
OWN_PREFIXES = ("PIHX_", "COMPOSE_")
OWN_NAMES = frozenset({"SERVICE_NAME"})
# Their values are masked by `config` unless --show-secrets: a name ending in one of these words, or
# with one as a `_`-separated part, in any case (OMRS_EXTRA_db_password, BIOMETRICS_LICENSE_BASE64).
_SECRET_WORDS = "PASSWORD|PASSWD|SECRET|SAS|TOKEN|KEY|LICENSE"
SECRET_NAME = re.compile(rf"(?:{_SECRET_WORDS})$|(?:^|_)(?:{_SECRET_WORDS})(?:_|$)", re.IGNORECASE)
MASK = "********"
# Env files hold secrets: readable by their owner only.
FILE_MODE = 0o600


def tools_dir():
    tools = os.environ.get("PIHX_TOOLS")
    if not tools:
        raise InstanceError("PIHX_TOOLS isn't set (run pihx through bin/pihx)")
    return Path(tools).absolute()


def option(args, name):
    """The value of --<name>=<value> or --<name> <value> in <args>, and the arguments left."""
    rest, value, i = [], None, 0
    while i < len(args):
        arg = args[i]
        if arg == f"--{name}":
            if i + 1 >= len(args):
                raise CliError(f"--{name} needs a value", status=2)
            value = args[i + 1]
            i += 2
            continue
        if arg.startswith(f"--{name}="):
            value = arg.split("=", 1)[1]
        else:
            rest.append(arg)
        i += 1
    return value, rest


def _no_arguments(args, command):
    if args:
        raise CliError(f"{command}: unexpected argument '{args[0]}'", status=2)


# --- which of the caller's values belong in which file -----------------------------------------

def _references(service, present):
    """The names a service's compose.yaml and its with-<other>.yaml files (for services in <present>)
    refer to."""
    files = [service.compose_file] + [f for other, f in sorted(service.with_files.items())
                                      if other in present]
    names = set()
    for f in files:
        names.update(REFERENCE.findall(f.read_text().replace("$$", "")))
    return names


def _own(name):
    return name.startswith(OWN_PREFIXES) or name in OWN_NAMES or not envfile.NAME.fullmatch(name)


def captured_values(tools, selected, environ):
    """Which of the caller's variables <environ> go in which env file: ({instance.env values},
    {service name: {name: value}}) for the services <selected> (a list of Service). Only a name that
    is set is written, and only into a file that knows it: instance.env for the names in the
    tools directory's instance.env.defaults; the owner's file for a name in a service's env.defaults;
    else the first service (by name) that captures its prefix (capture-env) or that its compose files
    refer to."""
    defaults_file = Path(tools) / instance_module.INSTANCE_DEFAULTS
    try:
        instance_names = set(envfile.parse(defaults_file.read_text())) \
            if defaults_file.is_file() else set()
    except ValueError as e:
        raise InstanceError(f"{defaults_file}: {e}") from None
    # A name two services define (the static test forbids it) belongs to the first by name.
    owner = {}
    for svc in sorted(services_module.all(tools).values(), key=lambda s: s.name):
        for name in svc.defaults:
            owner.setdefault(name, svc.name)
    ordered = sorted(selected, key=lambda s: s.name)
    present = {s.name for s in ordered}
    references = {s.name: _references(s, present) for s in ordered}
    instance_values, values = {}, {s.name: {} for s in ordered}
    for name in sorted(environ):
        if _own(name):
            continue
        if name in instance_names:
            instance_values[name] = environ[name]
        elif name in owner:
            if owner[name] in present:
                values[owner[name]][name] = environ[name]
        else:
            for svc in ordered:
                if any(name.startswith(p) for p in svc.manifest.capture_env) \
                        or name in references[svc.name]:
                    values[svc.name][name] = environ[name]
                    break
    return instance_values, values


def _text(values):
    try:
        return "".join(envfile.format_line(name, value) + "\n" for name, value in sorted(values.items()))
    except ValueError as e:
        raise InstanceError(str(e)) from None


def _write_new(path, text):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, FILE_MODE)
    with os.fdopen(fd, "w") as f:
        f.write(text)


def _check_requires(service, present):
    missing = [r for r in service.manifest.requires if r not in present]
    if missing:
        raise InstanceError(f"{service.name} requires {', '.join(missing)}: add "
                            f"{'it' if len(missing) == 1 else 'them'} to the instance too")


def _validate(instance):
    """Compose accepts the instance as it is (e.g. every required value is set); Compose's own
    message says why not."""
    compose_module.Compose(instance).run("config", "-q")


# --- commands -------------------------------------------------------------------------------------

def check_create(name, args):
    """create's checks before it writes anything (its arguments, an existing directory, the
    services and what they require): the services (Service) it would create <name> with."""
    value, rest = option(args, "services")
    _no_arguments(rest, "create")
    if value is None:
        raise CliError("create needs --services=<service>[,<service>...]", status=2)
    names = [n for n in value.split(",") if n]
    if not names or len(set(names)) != len(names):
        raise CliError("--services needs a comma-separated list of distinct services", status=2)
    instance_dir = instance_module.home() / name
    if os.path.lexists(instance_dir):
        raise InstanceError(f"{instance_dir} already exists")
    try:
        selected = [services_module.load(tools_dir(), n) for n in names]
    except services_module.ServiceError as e:
        raise InstanceError(str(e)) from None
    for svc in selected:
        _check_requires(svc, set(names))
    return selected


def cmd_create(name, args):
    selected = check_create(name, args)
    names = [s.name for s in selected]
    tools = tools_dir()
    home = instance_module.home()
    instance_dir = home / name
    instance_values, values = captured_values(tools, selected, dict(os.environ))
    files = {instance_module.INSTANCE_ENV: _text(instance_values)}
    files.update({f"{s}.env": _text(v) for s, v in values.items()})

    home.mkdir(parents=True, exist_ok=True)
    instance_dir.mkdir()
    try:
        for file_name, text in files.items():
            _write_new(instance_dir / file_name, text)
        (instance_dir / "tools").symlink_to(tools)
        _validate(Instance(name=name, dir=instance_dir, tools=tools,
                           services=sorted(selected, key=lambda s: s.name)))
    except BaseException:
        shutil.rmtree(instance_dir, ignore_errors=True)
        raise
    print(f"Created {instance_dir} with {', '.join(sorted(names))}", file=sys.stderr)
    return 0


def instances(home):
    """(directory, [service names]) for each instance under <home>: a directory with a valid
    instance name holding env files."""
    found = []
    for d in sorted(home.iterdir()) if home.is_dir() else []:
        if not d.is_dir() or instance_module.instance_name_error(d.name):
            continue
        svcs = sorted(f.name[:-len(".env")] for f in d.glob("*.env")
                      if f.name != instance_module.INSTANCE_ENV and not f.name.startswith("."))
        if svcs or (d / instance_module.INSTANCE_ENV).is_file():
            found.append((d, svcs))
    return found


def cmd_list(args):
    _no_arguments(args, "list")
    rows = []
    for d, svcs in instances(instance_module.home()):
        tools = d / "tools"
        # As written: other instances' tools are never resolved here.
        target = os.readlink(tools) if tools.is_symlink() else (
            "(directory)" if tools.is_dir() else "(none)")
        rows.append((d.name, ",".join(svcs) or "-", target))
    if rows:
        header = ("INSTANCE", "SERVICES", "TOOLS")
        widths = [max(len(r[i]) for r in rows + [header]) for i in range(2)]
        for row in [header] + rows:
            print(f"{row[0]:<{widths[0]}}  {row[1]:<{widths[1]}}  {row[2]}")
    return 0


def cmd_config(name, args):
    show = "--show-secrets" in args
    _no_arguments([a for a in args if a != "--show-secrets"], "config")
    values = instance_module.open(instance_module.home(), name, tools=tools_dir()).config()
    for key in sorted(values):
        value = values[key]
        if not show and value and SECRET_NAME.search(key):
            value = MASK
        print(f"{key}={value}")
    return 0


def check_add_service(name, args):
    """add-service's checks before it writes anything (its arguments, the instance, the service and
    what it requires): (the instance, the service to add)."""
    if len(args) != 1:
        raise CliError("usage: pihx <instance> add-service <service>", status=2)
    inst = instance_module.open(instance_module.home(), name, tools=tools_dir())
    try:
        svc = services_module.load(inst.tools, args[0])
    except services_module.ServiceError as e:
        raise InstanceError(str(e)) from None
    present = {s.name for s in inst.services}
    if svc.name in present:
        raise InstanceError(f"{name} already has {svc.name}")
    _check_requires(svc, present)
    return inst, svc


def add_service(inst, svc):
    """Adds <svc> to <inst> (from check_add_service): writes its env file from the caller's values
    and checks that Compose accepts the instance, removing the file if not. Returns the file. The
    caller holds the instance lock."""
    selected = inst.services + [svc]
    _, values = captured_values(inst.tools, selected, dict(os.environ))
    text = _text(values[svc.name])
    path = inst.dir / f"{svc.name}.env"
    _write_new(path, text)
    try:
        _validate(Instance(name=inst.name, dir=inst.dir, tools=inst.tools,
                           services=sorted(selected, key=lambda s: s.name)))
    except BaseException:
        path.unlink()
        raise
    return path


def cmd_add_service(name, args):
    inst, svc = check_add_service(name, args)
    with lock.hold(inst, lock.wait_seconds(), command="add-service"):
        add_service(inst, svc)
    print(f"Added {svc.name} to {name}", file=sys.stderr)
    return 0


def _containers(service):
    """The Compose services (containers) a service's compose.yaml defines."""
    try:
        data = services_module.parse_yaml(service.compose_file.read_text())
    except ValueError as e:
        raise InstanceError(f"{service.compose_file}: {e}") from None
    return sorted((data or {}).get("services") or {})


def cmd_remove_service(name, args):
    if len(args) != 1:
        raise CliError("usage: pihx <instance> remove-service <service>", status=2)
    inst = instance_module.open(instance_module.home(), name, tools=tools_dir())
    svc = next((s for s in inst.services if s.name == args[0]), None)
    if svc is None:
        raise InstanceError(f"{name} doesn't have {args[0]}")
    needing = [s.name for s in inst.services if svc.name in s.manifest.requires]
    if needing:
        raise InstanceError(f"{', '.join(needing)} requires {svc.name}: remove "
                            f"{'it' if len(needing) == 1 else 'them'} first")
    with lock.hold(inst, lock.wait_seconds(), command="remove-service"):
        # Its containers, not its volumes; with its env file still there for Compose to read.
        # Never with no names: that would remove every container of the project.
        containers = _containers(svc)
        if containers:
            compose_module.Compose(inst).run("rm", "-sf", *containers)
        else:
            print(f"{svc.name} defines no containers; only its env file is removed", file=sys.stderr)
        (inst.dir / f"{svc.name}.env").unlink()
    print(f"Removed {svc.name} from {name} (its volumes are kept)", file=sys.stderr)
    return 0


def cmd_use_tools(name, args):
    if len(args) != 1:
        raise CliError("usage: pihx <instance> use-tools <path>", status=2)
    # Not opened: the instance may not be readable by the checkout it has now.
    home = instance_module.home()
    error = instance_module.instance_name_error(name)
    if error:
        raise InstanceError(error)
    instance_dir = home / name
    if not instance_dir.is_dir():
        raise InstanceError(f"no instance '{name}': {instance_dir} doesn't exist")
    # The launcher's resolved path is the one it mounted; the argument as typed may go through a
    # link or `..` that doesn't resolve the same way here.
    cwd = os.environ.get("PIHX_CWD") or os.getcwd()
    target = Path(os.path.realpath(os.environ.get("PIHX_USE_TOOLS") or os.path.join(cwd, args[0])))
    if not (target / "bin" / "pihx").is_file() or not (target / "services").is_dir():
        raise InstanceError(f"{target} isn't a tools directory (no bin/pihx or services/)")
    link = instance_dir / "tools"
    if link.exists() and not link.is_symlink():
        raise InstanceError(f"{link} is a directory of its own, not one use-tools can replace (on a Puppet host "
                            "it is Puppet's git checkout): change it there")
    with lock.hold(instance_module.Instance(name, instance_dir, link, []), lock.wait_seconds(),
                   command="use-tools"):
        new = instance_dir / ".tools.new"
        if new.is_symlink():
            new.unlink()
        new.symlink_to(target)
        os.replace(new, link)
    print(f"{name} now runs {target}", file=sys.stderr)
    return 0
