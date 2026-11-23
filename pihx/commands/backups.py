"""backup, upload-backups, list-backups and copy-backup: the instance's backups (services/backups,
docs/backups.md).

The backups service runs the backup and upload jobs on their schedules inside its own container,
into the instance's backups volume. These commands run a job now (in that container, holding the
instance lock), and read the volume (in a throwaway container, with the instance running or not):

  backup            runs the backup job now
  upload-backups    runs the upload job now
  list-backups      the runs in the volume, and the jobs' status (status.json)
  copy-backup <run> --to=<dir>
                    copies a complete run into a new or empty directory, which
                    `initialize --from <dir>` restores from
"""

import json
import os
import re
import subprocess

from pihx import compose as compose_module, envfile, instance as instance_module, lock, volumes
from pihx.commands import CliError, archive
from pihx.commands.instance_cmds import option, tools_dir
from pihx.commands.lifecycle import exit_status

SERVICE = "backups"
# Where the jobs are in the backups container (services/backups/compose.yaml).
JOBS = {"backup": "/opt/backup/backup.sh", "upload-backups": "/opt/backup/upload.sh"}
# A complete run: <prefix>_<UTC timestamp>; .partial and .failed ones aren't backups.
COMPLETE_RUN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*_([0-9]{8}T[0-9]{6}Z)")
STATUS_FILE = "status.json"
UPLOADED_DIR = ".uploaded"


def _open(name):
    return instance_module.open(instance_module.home(), name, tools=tools_dir())


def _no_arguments(args, command):
    if args:
        raise CliError(f"unknown option '{args[0]}' for {command}", status=2)


def _require_service(inst):
    if not any(s.name == SERVICE for s in inst.services):
        raise CliError(f"{inst.name} doesn't have the {SERVICE} service (add it: 'pihx {inst.name} "
                       f"add-service {SERVICE}', with BACKUP_ARCHIVE_PASSWORD set)")


def _container_values(inst, compose):
    """The BACKUP_* values the backups container gets: its env.defaults and backups.env only
    (services/backups/compose.yaml), not the merged config, where instance.env would win."""
    service = next(s for s in inst.services if s.name == SERVICE)
    files = [service.dir / "env.defaults"]
    if (inst.dir / f"{SERVICE}.env").is_file():
        files.append(inst.dir / f"{SERVICE}.env")
    try:
        return envfile.merge(files, compose.environment())
    except ValueError as e:
        raise CliError(str(e)) from None


def _volume_exists(inst, compose):
    return volumes.backups_volume(inst.name) in volumes.listed(compose)


def _run_in_volume(inst, compose, script, *args, mounts=(), capture=True):
    """Runs the sh <script> with <args> in a throwaway container (the tools' ALPINE_IMAGE) that
    mounts the backups volume read-only at /b, plus <mounts> (docker run --mount values)."""
    command = ["run", "--rm", "--mount",
               f"type=volume,source={volumes.backups_volume(inst.name)},target=/b,readonly"]
    for mount in mounts:
        command += ["--mount", mount]
    command += [archive.alpine_image(inst), "sh", "-c", script, "sh", *args]
    return archive._docker(compose, *command, capture_output=capture, text=True)


# --- backup, upload-backups -----------------------------------------------------------------------

def _run_job(name, args, command):
    _no_arguments(args, command)
    inst = _open(name)
    _require_service(inst)
    compose = compose_module.Compose(inst)
    if command == "upload-backups" and not _container_values(inst, compose).get("BACKUP_UPLOAD"):
        print(f"Uploads aren't configured for {name} (BACKUP_UPLOAD is empty in backups.env): "
              "its backups stay in its backups volume.")
        return 0
    with lock.hold(inst, lock.wait_seconds(), command=command):
        running = compose.run("ps", "-q", "--status", "running", SERVICE, stdout=subprocess.PIPE,
                              text=True).stdout.split()
        if not running:
            raise CliError(f"{name}'s {SERVICE} container isn't running: start {name} first "
                           f"('pihx {name} start')")
        # Its output streams here as it goes; the run's own log is in the volume (list-backups).
        result = compose.run("exec", "-T", SERVICE, "bash", JOBS[command], check=False)
    return exit_status(result.returncode)


def cmd_backup(name, args):
    return _run_job(name, args, "backup")


def cmd_upload_backups(name, args):
    return _run_job(name, args, "upload-backups")


# --- list-backups ---------------------------------------------------------------------------------

# Prints a line "<run>\t<KiB>\t<uploaded: yes|no>" for each run directory, then "---", then
# status.json if there is one.
_LIST_SCRIPT = r'''
cd /b || exit 1
for d in */; do
    [ -d "$d" ] || continue
    d=${d%/}
    up=no
    [ -e ".uploaded/$d" ] && up=yes
    printf '%s\t%s\t%s\n' "$d" "$(du -sk "$d" | cut -f1)" "$up"
done
echo ---
[ -f status.json ] && cat status.json
exit 0
'''


def parse_listing(text):
    """(runs as [(name, state, KiB, uploaded)], status dict) from _LIST_SCRIPT's output. state is
    complete, failed or partial (a run being written, or one a stopped job left)."""
    runs_text, _, status_text = text.partition("---\n")
    runs = []
    for line in runs_text.splitlines():
        parts = line.split("\t")
        if len(parts) != 3 or not parts[1].isdigit():
            continue
        run, kb, uploaded = parts
        state = ("failed" if run.endswith(".failed") else "partial" if run.endswith(".partial")
                 else "complete" if COMPLETE_RUN.fullmatch(run) else None)
        if state:
            runs.append((run, state, int(kb), uploaded == "yes"))
    try:
        status = json.loads(status_text) if status_text.strip() else {}
    except ValueError:
        status = {}
    return runs, status if isinstance(status, dict) else {}


def _job_line(label, section):
    if not section:
        return f"{label}: never run"
    line = f"{label}: last {section.get('last_result', '?')} at {section.get('last_attempt', '?')}"
    if section.get("last_success"):
        line += f"; last success at {section['last_success']}"
    if section.get("last_error"):
        line += f"\n  error: {section['last_error']}"
    return line


def format_listing(runs, status):
    lines = []
    if runs:
        width = max(len(r[0]) for r in runs + [("RUN",)])
        lines.append(f"{'RUN':<{width}}  {'STATE':<8}  {'SIZE':>7}  UPLOADED")
        for run, state, kb, uploaded in runs:
            shown = ("yes" if uploaded else "no") if state == "complete" else "-"
            lines.append(f"{run:<{width}}  {state:<8}  {volumes.human(kb):>7}  {shown}")
    else:
        lines.append("No runs yet.")
    lines.append("")
    lines.append(_job_line("Backup", status.get("backup")))
    upload = status.get("upload")
    lines.append(_job_line("Upload", upload))
    if upload and "pending_runs" in upload:
        lines.append(f"  waiting to upload: {upload['pending_runs']} run(s), "
                     f"{volumes.human(int(upload.get('pending_bytes') or 0) // 1024)}")
    not_backed_up = (status.get("backup") or {}).get("not_backed_up") or []
    if not_backed_up:
        lines.append(f"Not backed up: {', '.join(not_backed_up)}")
    return "\n".join(lines)


def _listing(inst, compose):
    if not _volume_exists(inst, compose):
        raise CliError(f"{inst.name} has no backups volume ({volumes.backups_volume(inst.name)}): "
                       f"it gets one when it has the {SERVICE} service and starts")
    result = _run_in_volume(inst, compose, _LIST_SCRIPT)
    if result.returncode != 0:
        raise CliError(f"couldn't read {volumes.backups_volume(inst.name)}: "
                       f"{archive.stderr_of(result)}")
    return parse_listing(result.stdout)


def cmd_list_backups(name, args):
    _no_arguments(args, "list-backups")
    inst = _open(name)
    compose = compose_module.Compose(inst)
    runs, status = _listing(inst, compose)
    print(format_listing(runs, status))
    return 0


# --- copy-backup ----------------------------------------------------------------------------------

# Copies /b/<run> into /to as <uid:gid>; on failure, empties /to again.
_COPY_SCRIPT = r'''
cp -R "/b/$1/." /to/ && chown -R "$2" /to/.
status=$?
[ "$status" -eq 0 ] && exit 0
find /to -mindepth 1 -delete
exit "$status"
'''


def cmd_copy_backup(name, args):
    usage = f"usage: pihx {name} copy-backup <run>|latest --to=<dir>"
    to, rest = option(args, "to")
    if len(rest) != 1 or rest[0].startswith("-") or not to:
        raise CliError(usage, status=2)
    wanted = rest[0]
    inst = _open(name)
    compose = compose_module.Compose(inst)
    runs, _ = _listing(inst, compose)
    complete = [r for r in runs if r[1] == "complete"]
    if wanted == "latest":
        if not complete:
            raise CliError(f"{name} has no complete backup run yet (see 'pihx {name} list-backups')")
        # The newest by its timestamp: the volume can hold runs of an earlier BACKUP_PREFIX.
        run = max(complete, key=lambda r: COMPLETE_RUN.fullmatch(r[0]).group(1))
    else:
        run = next((r for r in runs if r[0] == wanted), None)
        if run is None:
            raise CliError(f"no run '{wanted}' in {volumes.backups_volume(name)} (see 'pihx {name} "
                           "list-backups')")
        if run[1] != "complete":
            raise CliError(f"{wanted} is {run[1]}, not a complete backup: only complete runs restore")
    dest = archive.destination(name, to)
    dest.make()
    try:
        archive.check_space(dest, run[2], what=run[0], holding="it holds")
    except BaseException:
        dest.discard()
        raise
    owner = f"{os.getuid()}:{os.getgid()}"
    result = _run_in_volume(inst, compose, _COPY_SCRIPT, run[0], owner,
                            mounts=[f'type=bind,"source={dest.path}",target=/to'])
    if result.returncode != 0:
        dest.discard()
        raise CliError(f"couldn't copy {run[0]} to {dest.path}: {archive.stderr_of(result)}")
    print(f"Copied {run[0]} to {dest.path}/ ({volumes.human(run[2])}). To restore it into a new "
          f"instance: pihx <instance> initialize --from {dest.path}")
    return 0
