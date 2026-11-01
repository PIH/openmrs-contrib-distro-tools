import subprocess
import unittest
from unittest import mock

from pihx.commands import CliError, wait


def done(stdout=""):
    return subprocess.CompletedProcess([], 0, stdout=stdout, stderr="")


class ContainersToWaitForTest(unittest.TestCase):
    """Which containers wait waits for, from docker ps and docker inspect (faked)."""

    def pick(self, *inspected):
        """inspected: (name, label, healthcheck, status, restart policy, exit code) per container."""
        lines = "\n".join("\t".join(c) for c in inspected)
        ids = "\n".join(f"id{i}" for i in range(len(inspected)))
        compose = mock.Mock()
        compose.environment.return_value = {"COMPOSE_PROJECT_NAME": "t"}
        inst = mock.Mock()
        inst.name = "t"
        with mock.patch.object(wait, "_docker", side_effect=lambda _c, *a: done(ids if a[0] == "ps" else lines)):
            return wait.containers_to_wait_for(inst, compose)

    def test_running_containers_with_a_healthcheck(self):
        self.assertEqual(self.pick(
            ("/t-db", "", "CMD-SHELL", "running", "unless-stopped", "0"),
            ("/t-openmrs", "fail-on-unhealthy", "CMD", "running", "unless-stopped", "0"),
            ("/t-setup", "", "", "running", "no", "0"),
        ), [("t-db", False), ("t-openmrs", True)])

    def test_a_crash_looping_container_between_restarts_is_waited_for(self):
        # Without it, wait would report the instance ready while OpenMRS keeps exiting
        self.assertEqual(self.pick(
            ("/t-db", "", "CMD-SHELL", "running", "unless-stopped", "0"),
            ("/t-openmrs", "fail-on-unhealthy", "CMD", "exited", "unless-stopped", "1"),
        ), [("t-db", False), ("t-openmrs", True)])
        self.assertEqual(self.pick(("/t-x", "", "CMD", "exited", "on-failure", "1")), [("t-x", False)])

    def test_containers_docker_doesnt_restart_are_left_out(self):
        self.assertEqual(self.pick(
            ("/t-db", "", "CMD-SHELL", "running", "unless-stopped", "0"),
            ("/t-setup", "", "CMD", "exited", "no", "0"),
            ("/t-job", "", "CMD", "exited", "on-failure", "0"),
        ), [("t-db", False)])

    def test_no_running_containers_is_refused(self):
        with self.assertRaisesRegex(CliError, "no running containers"):
            self.pick(("/t-setup", "", "", "exited", "no", "0"))
        with self.assertRaisesRegex(CliError, "no running containers"):
            self.pick()


if __name__ == "__main__":
    unittest.main()
