import os
import stat

from pihx import compose, instance
from pihx.tests.fixtures import TempDirTest, two_service_instance, write


class ComposeTest(TempDirTest):
    def setUp(self):
        super().setUp()
        self.home, self.tools = two_service_instance(self.root)
        self.kz = instance.open(self.home, "kz", tools=self.tools)
        self.dir = self.home / "kz"
        self.svc = self.tools / "services"
        self.env_files = [self.svc / "app" / "env.defaults", self.svc / "db" / "env.defaults",
                          self.dir / "app.env", self.dir / "db.env", self.dir / "instance.env"]
        self.compose_files = [self.svc / "app" / "compose.yaml", self.dir / "app.override.yaml",
                              self.svc / "db" / "compose.yaml"]

    def test_args(self):
        extra = self.root / "restore.yaml"
        args = compose.Compose(self.kz, extra_files=[extra]).args()
        expected = ["-p", "kz"]
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
        """A docker on PATH that records its arguments and SERVICE_NAME."""
        bin_dir = self.root / "bin"
        record = self.root / "record"
        docker = write(bin_dir / "docker",
                       f'#!/bin/sh\nprintf "%s\\n" "$SERVICE_NAME" "$@" > "{record}"\nexit {status}\n')
        docker.chmod(docker.stat().st_mode | stat.S_IXUSR)
        self.addCleanup(os.environ.__setitem__, "PATH", os.environ["PATH"])
        os.environ["PATH"] = f"{bin_dir}{os.pathsep}{os.environ['PATH']}"
        return record

    def test_run(self):
        record = self.fake_docker()
        c = compose.Compose(self.kz)
        result = c.run("ps", "--all")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(record.read_text().splitlines(),
                         ["kz", "compose"] + c.args() + ["ps", "--all"])

    def test_run_failure(self):
        self.fake_docker(status=3)
        c = compose.Compose(self.kz)
        with self.assertRaises(compose.ComposeError) as raised:
            c.run("up", "-d")
        self.assertIn("up -d", str(raised.exception))
        self.assertEqual(c.run("up", check=False).returncode, 3)
