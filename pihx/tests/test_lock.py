import contextlib
import io
import threading
import time

from pihx import instance, lock
from pihx.tests.fixtures import TempDirTest, two_service_instance


class LockTest(TempDirTest):
    def setUp(self):
        super().setUp()
        home, tools = two_service_instance(self.root)
        self.kz = instance.open(home, "kz", tools=tools)

    def test_refuses_while_held(self):
        with lock.hold(self.kz, 0, command="pihx kz initialize"):
            self.assertIn("pihx kz initialize", lock.holder(self.kz))
            with self.assertRaises(lock.LockError) as raised:
                with lock.hold(self.kz, 0, command="pihx kz start"):
                    pass
            self.assertIn("kz is busy", str(raised.exception))
            self.assertIn("pihx kz initialize", str(raised.exception))
            with self.assertRaises(lock.LockError):
                lock.check(self.kz)
        self.assertIsNone(lock.holder(self.kz))
        lock.check(self.kz)
        with lock.hold(self.kz, 0, command="pihx kz start"):
            pass

    def test_waits_when_asked(self):
        held, release = threading.Event(), threading.Event()

        def holder():
            with lock.hold(self.kz, 0, command="pihx kz run-service petl"):
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
        with contextlib.redirect_stderr(err), lock.hold(self.kz, 10, command="pihx kz start"):
            self.assertGreater(time.monotonic() - started, 0.3)
            self.assertIn("pihx kz start", lock.holder(self.kz))
        self.assertIn("kz is busy: pihx kz run-service petl", err.getvalue())

    def test_gives_up_after_waiting(self):
        with lock.hold(self.kz, 0, command="pihx kz initialize"):
            with self.assertRaises(lock.LockError) as raised, \
                    contextlib.redirect_stderr(io.StringIO()):
                with lock.hold(self.kz, 1, command="pihx kz start"):
                    pass
            self.assertIn("still busy after 1s", str(raised.exception))
