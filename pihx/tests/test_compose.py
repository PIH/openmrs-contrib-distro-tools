import os
import stat
from unittest import mock

from pihx import compose, instance
from pihx.tests.fixtures import TempDirTest, two_service_instance, write


class ComposeTest(TempDirTest):
    def setUp(self):
        super().setUp()
        self.home, self.tools = two_service_instance(self.root)
        self.kz = instance.open(self.home, "kz", tools=self.tools)
        self.dir = self.home / "kz"
        self.svc = self.tools / "services"
        self.env_files = [self.tools / "instance.env.defaults", self.svc / "app" / "env.defaults", self.svc / "db" / "env.defaults",
                          self.dir / "app.env", self.dir / "db.env", self.dir / "instance.env"]
        self.compose_files = [self.svc / "app" / "compose.yaml", self.dir / "app.override.yaml",
                              self.svc / "db" / "compose.yaml"]

    def test_args(self):
        extra = self.root / "restore.yaml"
        args = compose.Compose(self.kz, extra_files=[extra]).args()
        expected = ["-p", "kz", "--project-directory", str(self.dir)]
        for f in self.env_files:
            expected += ["--env-file", str(f)]
        for f in self.compose_files + [extra]:
            expected += ["-f", str(f)]
        self.assertEqual(args, expected)

    def test_env(self):
        env = compose.Compose(self.kz).env()
        self.assertEqual(env, {
            "COMPOSE_PROJECT_NAME": "kz",
            "COMPOSE_FILE": os.pathsep.join(str(f) for f in self.compose_files),
            "COMPOSE_ENV_FILES": ",".join(str(f) for f in self.env_files),
            "SERVICE_NAME": "kz",
            "PIHX_TOOLS": str(self.tools),
            "PIHX_INSTANCE_DIR": str(self.dir),
            "PIHX_INSTANCE": "kz",
        })

    def fake_docker(self, status=0):
        """A docker on PATH that records its arguments, then its environment."""
        bin_dir = self.root / "bin"
        record = self.root / "record"
        docker = write(bin_dir / "docker",
                       f'#!/bin/sh\n{{ printf "%s\\n" "$@"; echo --; env; }} > "{record}"\n'
                       f'exit {status}\n')
        docker.chmod(docker.stat().st_mode | stat.S_IXUSR)
        self.addCleanup(os.environ.__setitem__, "PATH", os.environ["PATH"])
        os.environ["PATH"] = f"{bin_dir}{os.pathsep}{os.environ['PATH']}"
        return record

    def test_run(self):
        record = self.fake_docker()
        c = compose.Compose(self.kz)
        result = c.run("ps", "--all")
        self.assertEqual(result.returncode, 0)
        args, env = record.read_text().split("--\n", 1)
        self.assertEqual(args.splitlines(), ["compose"] + c.args() + ["ps", "--all"])
        self.assertIn("SERVICE_NAME=kz", env.splitlines())

    def test_run_gets_only_pihx_values_and_passed_through_ones(self):
        record = self.fake_docker()
        polluted = {"OPENMRS_X": "from the caller", "TZ": "Mars/Base", "DOCKER_HOST": "unix:///s",
                    "HOME": "/home/caller"}
        with mock.patch.dict(os.environ, polluted):
            compose.Compose(self.kz).run("ps")
        env = dict(line.split("=", 1) for line in record.read_text().split("--\n", 1)[1].splitlines()
                   if "=" in line)
        self.assertNotIn("OPENMRS_X", env)
        self.assertNotIn("TZ", env)
        self.assertEqual(env["DOCKER_HOST"], "unix:///s")
        self.assertEqual(env["HOME"], "/home/caller")
        self.assertEqual(env["COMPOSE_PROJECT_NAME"], "kz")
        with mock.patch.dict(os.environ, polluted):
            self.assertEqual(set(compose.environment(self.kz)),
                             set(compose.Compose(self.kz).env())
                             | {n for n in compose.PASSED_THROUGH if n in os.environ})

    def test_run_failure(self):
        self.fake_docker(status=3)
        c = compose.Compose(self.kz)
        with self.assertRaises(compose.ComposeError) as raised:
            c.run("up", "-d")
        self.assertIn("up -d", str(raised.exception))
        self.assertEqual(c.run("up", check=False).returncode, 3)
