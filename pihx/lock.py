"""The instance lock: commands that change an instance hold <dir>/.lock while they run, and refuse
(or wait) while another command holds it. Puppet runs `pull` and `start` on every apply, which
mustn't happen part way through e.g. an initialize or a PETL run. flock releases the lock however
its holder exits."""

import contextlib
import fcntl
import os
import sys
import time

POLL_SECONDS = 0.1


class LockError(Exception):
    """The instance is busy."""


def _lock_file(instance):
    return instance.dir / ".lock"


def _open(instance):
    # Read-only is all flock needs, so a lock file another user created still works.
    return os.open(_lock_file(instance), os.O_RDONLY | os.O_CREAT, 0o644)


def _try_lock(fd):
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except BlockingIOError:
        return False


def holder(instance):
    """What holds the instance's lock (the command, its pid and start time), or None."""
    if not _lock_file(instance).exists():
        return None
    fd = os.open(_lock_file(instance), os.O_RDONLY)
    try:
        if _try_lock(fd):
            return None
        return _lock_file(instance).read_text().strip() or "another command"
    finally:
        os.close(fd)


def _acquire(instance, wait_seconds):
    fd = _open(instance)
    try:
        if _try_lock(fd):
            return fd
        if wait_seconds <= 0:
            raise LockError(f"{instance.name} is busy: {holder(instance)} -- run this again once "
                            "that finishes.")
        print(f"{instance.name} is busy: {holder(instance)} -- waiting up to {wait_seconds}s",
              file=sys.stderr)
        deadline = time.monotonic() + wait_seconds
        while time.monotonic() < deadline:
            time.sleep(POLL_SECONDS)
            if _try_lock(fd):
                return fd
        raise LockError(f"{instance.name} is still busy after {wait_seconds}s: {holder(instance)}")
    except BaseException:
        os.close(fd)
        raise


@contextlib.contextmanager
def hold(instance, wait_seconds, command=None):
    """Holds the instance's lock for the with block, waiting up to <wait_seconds> for it. The lock
    file names <command> (default: this pihx command line) for anyone refused meanwhile."""
    fd = _acquire(instance, wait_seconds)
    try:
        if command is None:
            command = " ".join(["pihx", *sys.argv[1:]])
        try:
            _lock_file(instance).write_text(
                f"{command} (pid {os.getpid()}, started {time.strftime('%Y-%m-%d %H:%M:%S')})\n")
        except OSError:
            pass  # e.g. another user's lock file: the lock holds, only the message is lost
        yield
    finally:
        os.close(fd)


def check(instance, wait_seconds=0):
    """Refuses (after waiting up to <wait_seconds>) if another command holds the lock, without
    holding it."""
    os.close(_acquire(instance, wait_seconds))
