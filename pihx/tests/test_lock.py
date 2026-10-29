import contextlib
import io
import sys
import threading
import time
from unittest import mock

from pihx import instance, lock
from pihx.tests.fixtures import TempDirTest, two_service_instance


class LockTest(TempDirTest):
    def setUp(self):
        super().setUp()
        home, tools = two_service_instance(self.root)
        self.kz = instance.open(home, "kz", tools=tools)

    def test_refuses_while_held(self):
        with lock.hold(self.kz, 0, command="initialize"):
            self.assertIn("pihx kz initialize", lock.holder(self.kz))
            with self.assertRaises(lock.LockError) as raised:
                with lock.hold(self.kz, 0, command="start"):
                    pass
            self.assertIn("kz is busy", str(raised.exception))
            self.assertIn("pihx kz initialize", str(raised.exception))
            with self.assertRaises(lock.LockError):
                lock.check(self.kz)
        self.assertIsNone(lock.holder(self.kz))
        lock.check(self.kz)
        with lock.hold(self.kz, 0, command="start"):
            pass

    def test_waits_when_asked(self):
        held, release = threading.Event(), threading.Event()

        def holder():
            with lock.hold(self.kz, 0, command="run-service"):
                held.set()
                release.wait(10)

        thread = threading.Thread(target=holder)
        thread.start()
        self.addCleanup(thread.join)
        self.addCleanup(release.set)
        held.wait(10)
        threading.Timer(0.5, release.set).start()
        started = time.monotonic()
        err = io.StringIO()
        with contextlib.redirect_stderr(err), lock.hold(self.kz, 10, command="start"):
            self.assertGreater(time.monotonic() - started, 0.3)
            self.assertIn("pihx kz start", lock.holder(self.kz))
        self.assertIn("kz is busy: pihx kz run-service (pid", err.getvalue())

    def test_gives_up_after_waiting(self):
        with lock.hold(self.kz, 0, command="initialize"):
            with self.assertRaises(lock.LockError) as raised, \
                    contextlib.redirect_stderr(io.StringIO()):
                with lock.hold(self.kz, 1, command="start"):
                    pass
            self.assertIn("still busy after 1s", str(raised.exception))


class LockMessageTest(TempDirTest):
    def setUp(self):
        super().setUp()
        home, tools = two_service_instance(self.root)
        self.kz = instance.open(home, "kz", tools=tools)

    def test_default_command_is_the_command_name_only(self):
        with mock.patch.object(sys, "argv", ["pihx", "kz", "initialize", "--password=secret"]):
            with lock.hold(self.kz, 0):
                self.assertRegex(lock.holder(self.kz), r"^pihx kz initialize \(pid \d+, started ")
                self.assertNotIn("secret", (self.kz.dir / ".lock").read_text())

    def test_an_empty_lock_file_still_names_something(self):
        with lock.hold(self.kz, 0, command="start"):
            (self.kz.dir / ".lock").write_text("")
            with self.assertRaises(lock.LockError) as raised:
                lock.check(self.kz)
        self.assertIn("kz is busy: another command", str(raised.exception))
