"""The openmrs-docker extension, against this checkout's own services, with Docker Compose faked."""

import contextlib
import io
import subprocess
from pathlib import Path
from unittest import mock

from openmrs import extension
from pihx import cli, compose
from pihx.commands import initialize, lifecycle
from pihx.tests.fixtures import write
from pihx.tests.test_instance_cmds import CommandTest

TOOLS = Path(__file__).resolve().parents[2]


class ExtensionTest(CommandTest):
    def setUp(self):
        super().setUp()
        self.tools = TOOLS
        self.set_env({})

    def main(self, argv, ext):
        out, err = io.StringIO(), io.StringIO()

        def fake_run(compose_self, *args, **kwargs):
            self.compose_calls.append((args, [str(f) for f in compose_self.extra_files]))
            return subprocess.CompletedProcess([], 0, stdout="")
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), \
                mock.patch.object(compose.Compose, "run", fake_run):
            status = cli.main(list(argv), extension=ext)
        return status, out.getvalue(), err.getvalue()

    def openmrs_docker(self, *argv):
        """Runs the extension; returns (status, stdout, stderr)."""
        return self.main(argv, extension)

    def pihx(self, *argv):
        return self.main(argv, None)

    def make(self, name="kz", services=("openmrs-db", "openmrs"), **files):
        """An instance directory as create leaves it, with <files> ({stem: text})."""
        for svc in services:
            write(self.home / name / f"{svc}.env", files.pop(svc, ""))
        write(self.home / name / "instance.env", files.pop("instance", ""))
        return self.home / name


class CommandLineTest(ExtensionTest):
    def test_pihx_s_own_commands_work_the_same(self):
        self.make(openmrs="OPENMRS_IMAGE_NAME='pih/emr'\n")
        for argv in (("kz", "config"), ("kz", "openmrs-db"), ("list",), ("version",),
                     ("kz", "nosuch"), ("kz",), ("Bad",)):
            with self.subTest(argv=argv):
                self.assertEqual(self.openmrs_docker(*argv), self.pihx(*argv))

    def test_help_is_pihx_s_and_the_extension_s(self):
        for argv in (("help",), ("kz", "help")):
            with self.subTest(argv=argv):
                status, out, _ = self.openmrs_docker(*argv)
                self.assertEqual(status, 0)
                self.assertEqual(out, self.pihx(*argv)[1] + extension.USAGE)
        self.assertIn("start [--build] [--dev]", extension.USAGE)
        self.assertNotIn("_distro-dir", extension.USAGE)

    def test_the_old_create_order_and_dropped_commands_are_pihx_s_usual_errors(self):
        self.make()
        for argv in (("create", "kz"), ("kz", "fingerprint"), ("kz", "reset-openmrs-db-accounts"),
                     ("kz", "sync")):
            with self.subTest(argv=argv):
                status, out, err = self.openmrs_docker(*argv)
                self.assertEqual((status, out, err), self.pihx(*argv))
                self.assertEqual(status, 2)
                self.assertIn("unknown command", err)

    def test_start_and_update_refuse_arguments_as_pihx_s_do(self):
        self.make()
        for argv, pihx in [(("start", "foo"), ("start", "foo")),
                           (("start", "--build", "foo"), ("start", "foo")),
                           (("update", "--force", "--dev"), ("update", "--force"))]:
            with self.subTest(argv=argv):
                result = self.openmrs_docker("kz", *argv)
                self.assertEqual(result, self.pihx("kz", *pihx))
                self.assertEqual(result[0], 2)
        self.assertEqual(self.compose_calls, [])

    def test_build_refuses_an_option(self):
        self.make()
        status, _, err = self.openmrs_docker("kz", "build", "--dev")
        self.assertEqual(status, 2)
        self.assertIn("unknown option '--dev' for build", err)


class CreateTest(ExtensionTest):
    def test_the_instance_first_with_the_default_services_and_the_distro_dir_in_openmrs_env(self):
        self.set_env({"OPENMRS_IMAGE_NAME": "pih/emr", "OPENMRS_DISTRO_DIR": "/src/distro",
                      "TZ": "Africa/Maseru"})
        status, _, err = self.openmrs_docker("kz", "create")
        self.assertEqual(status, 0, err)
        self.assertEqual(sorted(p.name for p in (self.home / "kz").glob("*.env")),
                         ["instance.env", "openmrs-db.env", "openmrs.env"])
        self.assertEqual(self.read("kz", "instance.env"), "TZ='Africa/Maseru'\n")
        self.assertEqual(self.read("kz", "openmrs.env"),
                         "OPENMRS_IMAGE_NAME='pih/emr'\nOPENMRS_DISTRO_DIR='/src/distro'\n")
        self.assertEqual((self.home / "kz" / "openmrs.env").stat().st_mode & 0o777, 0o600)

    def test_pihx_s_services_option(self):
        self.set_env({"OPENMRS_DISTRO_DIR": "/src/distro"})
        status, _, err = self.openmrs_docker("kz", "create", "--services", "openmrs-db")
        self.assertEqual(status, 0, err)
        self.assertEqual(sorted(p.name for p in (self.home / "kz").glob("*.env")),
                         ["instance.env", "openmrs-db.env"])
        self.assertNotIn("OPENMRS_DISTRO_DIR", self.read("kz", "openmrs-db.env"))

    def test_openmrs_needs_its_image(self):
        status, _, err = self.openmrs_docker("kz", "create")
        self.assertEqual(status, 1)
        self.assertIn("OPENMRS_IMAGE_NAME must be set", err)
        self.assertFalse((self.home / "kz").exists())

    def test_the_distro_dir_must_be_absolute_and_fit_an_env_file(self):
        for value, message in (("relative", "OPENMRS_DISTRO_DIR must be an absolute path"),
                               ("/it's", "OPENMRS_DISTRO_DIR contains a single quote")):
            with self.subTest(value=value):
                self.set_env({"OPENMRS_IMAGE_NAME": "pih/emr", "OPENMRS_DISTRO_DIR": value})
                status, _, err = self.openmrs_docker("kz", "create")
                self.assertEqual(status, 1)
                self.assertIn(message, err)
                self.assertFalse((self.home / "kz").exists())

    def test_pihx_s_create_errors(self):
        status, out, err = self.openmrs_docker("kz", "create", "extra", "--services=openmrs-db")
        self.assertEqual((status, out, err),
                         self.pihx("kz", "create", "extra", "--services=openmrs-db"))
        self.assertEqual(status, 2)


class ModesTest(ExtensionTest):
    DISTRO = {"openmrs": "OPENMRS_DISTRO_DIR='/src/distro'\n"}

    def test_dev_and_build_add_their_overlays(self):
        self.make(**self.DISTRO)
        modes = TOOLS / "openmrs" / "modes"
        with mock.patch.object(lifecycle, "instance_images", return_value=set()):
            status, _, err = self.openmrs_docker("kz", "start", "--dev", "--build")
        self.assertEqual(status, 0, err)
        self.assertEqual(self.compose_calls[0], (("build",), [str(modes / "dev.yaml"),
                                                              str(modes / "build.yaml")]))
        self.assertEqual(self.compose_calls[1][0], ("up", "-d"))

    def test_update_pulls_then_builds(self):
        self.make(**self.DISTRO)
        with mock.patch.object(lifecycle, "instance_images", return_value=set()):
            status, _, err = self.openmrs_docker("kz", "update", "--build")
        self.assertEqual(status, 0, err)
        self.assertEqual([c[0][0] for c in self.compose_calls][:3], ["pull", "build", "up"])

    def test_start_and_update_without_options_are_pihx_s(self):
        self.make()
        for command in ("start", "update"):
            with self.subTest(command=command), \
                    mock.patch.object(lifecycle, f"cmd_{command}", return_value=0) as pihx:
                status, _, _ = self.openmrs_docker("kz", command)
            self.assertEqual(status, 0)
            pihx.assert_called_once_with("kz", [])

    def test_dev_build_and_the_build_command_need_the_distro_dir(self):
        self.make()
        for argv in (("start", "--dev"), ("update", "--build"), ("build",),
                     ("_distro-dir", "build")):
            with self.subTest(argv=argv):
                status, _, err = self.openmrs_docker("kz", *argv)
                self.assertEqual(status, 1)
                self.assertIn("OPENMRS_DISTRO_DIR must be set in", err)
                self.assertIn("openmrs.env", err)
        self.assertEqual(self.compose_calls, [])

    def test_the_distro_dir_is_the_instance_s_not_the_caller_s(self):
        self.make(**self.DISTRO)
        self.set_env({"OPENMRS_DISTRO_DIR": "/elsewhere"})
        status, out, _ = self.openmrs_docker("kz", "_distro-dir", "start", "--build")
        self.assertEqual((status, out), (0, "/src/distro\n"))

    def test_the_build_command_is_checked_before_the_build(self):
        self.make(**self.DISTRO)
        for args, message in [(("start", "--force"), "unknown option '--force' for start"),
                              (("build", "--dev"), "unknown option '--dev' for build"),
                              (("stop",), "usage: _distro-dir"),
                              ((), "usage: _distro-dir")]:
            with self.subTest(args=args):
                status, out, err = self.openmrs_docker("kz", "_distro-dir", *args)
                self.assertEqual((status, out), (2, ""))
                self.assertIn(message, err)
        self.make("noapp", services=("openmrs-db",))
        status, _, err = self.openmrs_docker("noapp", "_distro-dir", "build")
        self.assertIn("no openmrs service", err)
        with mock.patch.object(extension.lock, "check",
                               side_effect=extension.lock.LockError("kz is busy")):
            status, out, err = self.openmrs_docker("kz", "_distro-dir", "build")
        self.assertEqual((status, out), (1, ""))
        self.assertIn("kz is busy", err)

    def test_the_distro_dir_must_be_absolute(self):
        self.make(openmrs="OPENMRS_DISTRO_DIR='src/distro'\n")
        status, _, err = self.openmrs_docker("kz", "_distro-dir", "build")
        self.assertEqual(status, 1)
        self.assertIn("must be an absolute path", err)


class InitializeTest(ExtensionTest):
    def test_is_pihx_s(self):
        self.make()
        with mock.patch.object(initialize, "cmd_initialize", return_value=0) as pihx:
            status, _, _ = self.openmrs_docker("kz", "initialize", "--from", "x")
        self.assertEqual(status, 0)
        pihx.assert_called_once_with("kz", ["--from", "x"])

    def test_a_seed_pihx_can_not_restore_gets_the_old_format_hint(self):
        self.make()
        error = initialize.SeedError("pih/seed:latest isn't a seed this version restores")
        with mock.patch.object(initialize, "restore_image", side_effect=error):
            status, _, err = self.openmrs_docker("kz", "initialize", "--from-image", "pih/seed")
        self.assertEqual(status, 1)
        self.assertIn("isn't a seed this version restores. It's probably an old-format seed", err)
        self.assertIn("openmrs/seed/Dockerfile", err)
