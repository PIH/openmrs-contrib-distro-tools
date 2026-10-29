import contextlib
import io
import os
import stat
from unittest import mock

from pihx import cli, compose, instance, lock
from pihx.tests.fixtures import TempDirTest, two_service_instance, two_service_tools, write


def run(argv):
    """Runs cli.main, returning (status, stdout, stderr)."""
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        status = cli.main(argv)
    return status, out.getvalue(), err.getvalue()


class CommandTest(TempDirTest):
    """Commands run against a fixture checkout, with Docker Compose faked."""

    def setUp(self):
        super().setUp()
        self.tools = two_service_tools(self.root)
        self.home = self.root / "home"
        self.home.mkdir()
        self.compose_calls = []
        self.compose_error = None
        self.set_env({})

    def set_env(self, environ):
        patcher = mock.patch.dict(os.environ, environ, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)
        os.environ.update({"PIHX_HOME": str(self.home), "PIHX_TOOLS": str(self.tools),
                           "PIHX_CWD": str(self.root), **environ})

    def run_pihx(self, *argv):
        def fake_run(compose_self, *args, **kwargs):
            self.compose_calls.append(args)
            if self.compose_error:
                raise self.compose_error
        with mock.patch.object(compose.Compose, "run", fake_run):
            return run(list(argv))

    def read(self, instance_name, file_name):
        return (self.home / instance_name / file_name).read_text()


class CreateTest(CommandTest):
    def test_values_are_written_to_the_file_that_owns_them(self):
        self.set_env({"DB_PASSWORD": "pa ss$word", "APP_PORT": "9000", "TZ": "Africa/Kigali",
                      "DB_OPT_x": "1", "UNRELATED": "no", "PIHX_HOME": str(self.home),
                      "SERVICE_NAME": "x", "COMPOSE_FILE": "x"})
        status, _, err = self.run_pihx("kz", "create", "--services=app,db")
        self.assertEqual(status, 0, err)
        self.assertEqual(self.read("kz", "db.env"), "DB_OPT_x='1'\nDB_PASSWORD='pa ss$word'\n")
        self.assertEqual(self.read("kz", "app.env"), "APP_PORT='9000'\n")
        self.assertEqual(self.read("kz", "instance.env"), "TZ='Africa/Kigali'\n")
        self.assertEqual(sorted(p.name for p in (self.home / "kz").iterdir()),
                         ["app.env", "db.env", "instance.env", "tools"])
        self.assertEqual(os.readlink(self.home / "kz" / "tools"), str(self.tools))
        self.assertEqual(self.compose_calls, [("config", "-q")])

    def test_nothing_is_written_for_unset_defaults(self):
        status, _, err = self.run_pihx("kz", "create", "--services=db")
        self.assertEqual(status, 0, err)
        for name in ("db.env", "instance.env"):
            self.assertEqual(self.read("kz", name), "")

    def test_files_are_private(self):
        self.set_env({"DB_PASSWORD": "x"})
        self.run_pihx("kz", "create", "--services=db")
        for name in ("db.env", "instance.env"):
            self.assertEqual(stat.S_IMODE(os.stat(self.home / "kz" / name).st_mode), 0o600)

    def test_names_a_compose_file_refers_to_are_captured_without_a_default(self):
        write(self.tools / "services" / "app" / "compose.yaml",
              "services:\n  app:\n    image: x\n    environment:\n"
              "      S: ${APP_SECRET:?set it}\n      T: $$NOT_A_REFERENCE\n")
        write(self.tools / "services" / "app" / "with-db.yaml",
              "services:\n  app:\n    environment:\n      W: ${APP_WITH}\n")
        self.set_env({"APP_SECRET": "s", "APP_WITH": "w", "NOT_A_REFERENCE": "n"})
        self.run_pihx("kz", "create", "--services=app,db")
        self.assertEqual(self.read("kz", "app.env"), "APP_SECRET='s'\nAPP_WITH='w'\n")
        self.assertEqual(self.read("kz", "db.env"), "")

    def test_a_name_two_services_define_goes_to_the_first_by_name(self):
        write(self.tools / "services" / "app" / "env.defaults", "APP_PORT=1\nDB_PORT=2\n")
        self.set_env({"DB_PORT": "3"})
        self.run_pihx("kz", "create", "--services=app,db")
        self.assertEqual(self.read("kz", "app.env"), "DB_PORT='3'\n")
        self.assertEqual(self.read("kz", "db.env"), "")

    def test_a_value_another_service_owns_is_written_only_there(self):
        # app refers to DB_PASSWORD, which db's defaults own.
        write(self.tools / "services" / "app" / "compose.yaml",
              "services:\n  app:\n    image: x\n    environment:\n      P: ${DB_PASSWORD}\n")
        self.set_env({"DB_PASSWORD": "p"})
        self.run_pihx("kz", "create", "--services=app,db")
        self.assertEqual(self.read("kz", "db.env"), "DB_PASSWORD='p'\n")
        self.assertEqual(self.read("kz", "app.env"), "")

    def test_services_are_required_and_must_exist(self):
        status, _, err = self.run_pihx("kz", "create")
        self.assertEqual(status, 2)
        self.assertIn("error:", err)
        status, _, err = self.run_pihx("kz", "create", "--services=nosuch")
        self.assertNotEqual(status, 0)
        self.assertTrue(err.strip().splitlines()[-1].startswith("error:"))
        self.assertFalse((self.home / "kz").exists())

    def test_refuses_a_missing_requires(self):
        status, _, err = self.run_pihx("kz", "create", "--services=app")
        self.assertNotEqual(status, 0)
        self.assertIn("app requires db", err)
        self.assertFalse((self.home / "kz").exists())

    def test_refuses_an_existing_directory(self):
        (self.home / "kz").mkdir()
        write(self.home / "kz" / "keep", "x")
        status, _, err = self.run_pihx("kz", "create", "--services=db")
        self.assertNotEqual(status, 0)
        self.assertIn("already exists", err)
        self.assertEqual(self.read("kz", "keep"), "x")

    def test_a_compose_failure_leaves_nothing_behind(self):
        self.compose_error = compose.ComposeError("docker compose config -q failed (exit 1)")
        status, _, err = self.run_pihx("kz", "create", "--services=db")
        self.assertNotEqual(status, 0)
        self.assertEqual(err.strip().splitlines()[-1],
                         "error: docker compose config -q failed (exit 1)")
        self.assertFalse((self.home / "kz").exists())

    def test_a_value_an_env_file_cant_hold_is_an_error_naming_it(self):
        self.set_env({"DB_PASSWORD": "it's"})
        status, _, err = self.run_pihx("kz", "create", "--services=db")
        self.assertNotEqual(status, 0)
        self.assertIn("DB_PASSWORD", err)
        self.assertFalse((self.home / "kz").exists())


class ServiceManagementTest(CommandTest):
    def setUp(self):
        super().setUp()
        two_service_instance(self.root)  # the instance "kz": db and app
        self.set_env({})

    def test_add_service(self):
        (self.home / "kz" / "app.env").unlink()
        self.set_env({"APP_PORT": "1234", "DB_PORT": "1"})
        status, _, err = self.run_pihx("kz", "add-service", "app")
        self.assertEqual(status, 0, err)
        self.assertEqual(self.read("kz", "app.env"), "APP_PORT='1234'\n")
        self.assertEqual(stat.S_IMODE(os.stat(self.home / "kz" / "app.env").st_mode), 0o600)
        self.assertEqual(self.compose_calls, [("config", "-q")])

    def test_add_service_refusals(self):
        status, _, err = self.run_pihx("kz", "add-service", "app")
        self.assertIn("already has app", err)
        (self.home / "kz" / "db.env").unlink()
        (self.home / "kz" / "app.env").unlink()
        status, _, err = self.run_pihx("kz", "add-service", "app")
        self.assertIn("app requires db", err)
        status, _, err = self.run_pihx("kz", "add-service", "nosuch")
        self.assertNotEqual(status, 0)
        self.assertIn("error:", err)

    def test_add_service_rolls_back_when_compose_refuses(self):
        (self.home / "kz" / "app.env").unlink()
        self.compose_error = compose.ComposeError("nope")
        status, _, err = self.run_pihx("kz", "add-service", "app")
        self.assertNotEqual(status, 0)
        self.assertFalse((self.home / "kz" / "app.env").exists())

    def test_remove_service_removes_its_containers_and_file(self):
        status, _, err = self.run_pihx("kz", "remove-service", "app")
        self.assertEqual(status, 0, err)
        self.assertEqual(self.compose_calls, [("rm", "-sf", "app")])
        self.assertFalse((self.home / "kz" / "app.env").exists())
        self.assertTrue((self.home / "kz" / "db.env").exists())

    def test_remove_service_never_calls_rm_without_names(self):
        write(self.tools / "services" / "app" / "compose.yaml", "services: {}\n")
        status, _, err = self.run_pihx("kz", "remove-service", "app")
        self.assertEqual(status, 0, err)
        self.assertEqual(self.compose_calls, [])
        self.assertFalse((self.home / "kz" / "app.env").exists())

    def test_remove_service_refuses_one_another_requires(self):
        status, _, err = self.run_pihx("kz", "remove-service", "db")
        self.assertNotEqual(status, 0)
        self.assertIn("app requires db", err)
        self.assertTrue((self.home / "kz" / "db.env").exists())
        self.assertEqual(self.compose_calls, [])

    def test_remove_service_keeps_its_file_when_compose_fails(self):
        self.compose_error = compose.ComposeError("boom")
        status, _, _ = self.run_pihx("kz", "remove-service", "app")
        self.assertNotEqual(status, 0)
        self.assertTrue((self.home / "kz" / "app.env").exists())

    def test_changes_hold_the_lock(self):
        holder = instance.open(self.home, "kz", tools=self.tools)
        with lock.hold(holder, 0, command="update"):
            status, _, err = self.run_pihx("kz", "remove-service", "app")
        self.assertNotEqual(status, 0)
        self.assertIn("kz is busy", err)
        self.assertTrue((self.home / "kz" / "app.env").exists())


class ConfigAndListTest(CommandTest):
    def setUp(self):
        super().setUp()
        two_service_instance(self.root)
        self.set_env({})

    def test_config_masks_secrets(self):
        write(self.home / "kz" / "db.env",
              "DB_PASSWORD='hunter2'\nDB_API_KEY=k\nDB_TOKEN=t\nDB_CLIENT_SECRET=s\nDB_SAS=x\n"
              "DB_KEYS=visible\nDB_PORT=1\nOMRS_EXTRA_db_password=p\nOMRS_EXTRA_smtp_passwd=p\n"
              "BIOMETRICS_LICENSE_BASE64=l\nOMRS_EXTRA_api_token_value=t\nDB_ROOTPASSWORD=r\n")
        status, out, _ = self.run_pihx("kz", "config")
        self.assertEqual(status, 0)
        self.assertNotIn("hunter2", out)
        for name in ("DB_PASSWORD", "DB_API_KEY", "DB_TOKEN", "DB_CLIENT_SECRET", "DB_SAS",
                     "OMRS_EXTRA_db_password", "OMRS_EXTRA_smtp_passwd", "BIOMETRICS_LICENSE_BASE64",
                     "OMRS_EXTRA_api_token_value", "DB_ROOTPASSWORD"):
            self.assertIn(f"{name}=********", out.splitlines())
        self.assertIn("DB_KEYS=visible", out.splitlines())
        self.assertIn("DB_PORT=1", out.splitlines())
        self.assertIn("TZ=Africa/Kigali", out.splitlines())

        status, out, _ = self.run_pihx("kz", "config", "--show-secrets")
        self.assertIn("DB_PASSWORD=hunter2", out.splitlines())

    def test_config_of_a_missing_instance_is_an_error(self):
        status, _, err = self.run_pihx("nosuch", "config")
        self.assertNotEqual(status, 0)
        self.assertTrue(err.startswith("error:"))

    def test_list_shows_links_as_written_without_resolving_them(self):
        (self.home / "kz" / "tools").symlink_to(self.root / "gone")
        write(self.home / "puppet" / "db.env", "")
        (self.home / "puppet" / "tools").mkdir()
        (self.home / "empty").mkdir()
        (self.home / "Not_An_Instance").mkdir()
        write(self.home / "a-file", "")
        status, out, err = self.run_pihx("list")
        self.assertEqual(status, 0, err)
        lines = [line.split() for line in out.splitlines()]
        self.assertEqual(lines[0], ["INSTANCE", "SERVICES", "TOOLS"])
        self.assertEqual(lines[1:], [["kz", "app,db", str(self.root / "gone")],
                                     ["puppet", "db", "(directory)"]])

    def test_list_with_no_instances_prints_nothing(self):
        self.set_env({"PIHX_HOME": str(self.root / "nowhere")})
        self.assertEqual(self.run_pihx("list"), (0, "", ""))


class UseToolsTest(CommandTest):
    def setUp(self):
        super().setUp()
        two_service_instance(self.root)
        self.set_env({})
        self.other = self.root / "other"
        write(self.other / "bin" / "pihx", "#!/bin/sh\n")
        (self.other / "services").mkdir()
        (self.home / "kz" / "tools").symlink_to(self.tools)

    def test_replaces_the_link_with_an_absolute_path(self):
        os.symlink(self.other, self.root / "alias")
        status, _, err = self.run_pihx("kz", "use-tools", "alias")
        self.assertEqual(status, 0, err)
        self.assertEqual(os.readlink(self.home / "kz" / "tools"), str(self.other))
        self.assertEqual(sorted(p.name for p in (self.home / "kz").iterdir() if "tools" in p.name),
                         ["tools"])

    def test_uses_the_launchers_resolved_path(self):
        self.set_env({"PIHX_USE_TOOLS": str(self.other)})
        status, _, err = self.run_pihx("kz", "use-tools", "as/typed/../alias")
        self.assertEqual(status, 0, err)
        self.assertEqual(os.readlink(self.home / "kz" / "tools"), str(self.other))

    def test_replaces_a_dangling_link(self):
        (self.home / "kz" / "tools").unlink()
        (self.home / "kz" / "tools").symlink_to(self.root / "gone")
        status, _, err = self.run_pihx("kz", "use-tools", str(self.other))
        self.assertEqual(status, 0, err)
        self.assertEqual(os.readlink(self.home / "kz" / "tools"), str(self.other))

    def test_refuses_what_isnt_a_checkout(self):
        (self.root / "empty").mkdir()
        status, _, err = self.run_pihx("kz", "use-tools", str(self.root / "empty"))
        self.assertNotEqual(status, 0)
        self.assertIn("isn't a distro-tools checkout", err)
        self.assertEqual(os.readlink(self.home / "kz" / "tools"), str(self.tools))

    def test_refuses_to_replace_a_real_directory(self):
        (self.home / "kz" / "tools").unlink()
        (self.home / "kz" / "tools").mkdir()
        status, _, err = self.run_pihx("kz", "use-tools", str(self.other))
        self.assertNotEqual(status, 0)
        self.assertIn("isn't a link", err)
        self.assertTrue((self.home / "kz" / "tools").is_dir())
        self.assertFalse((self.home / "kz" / "tools").is_symlink())


class ErrorLineTest(CommandTest):
    def test_error_types_end_with_an_error_line_and_a_status(self):
        from pihx import services
        for error in (instance.InstanceError("a"), services.ServiceError("b"),
                      compose.ComposeError("c"), lock.LockError("d")):
            with self.subTest(error=type(error).__name__):
                with mock.patch.dict(cli.INSTANCE_COMMANDS, {"config": mock.Mock(side_effect=error)}):
                    status, _, err = run(["kz", "config"])
                self.assertEqual(status, 1)
                self.assertEqual(err, f"error: {error}\n")

    def test_lock_wait_must_be_a_number(self):
        self.set_env({"PIHX_LOCK_WAIT": "soon"})
        with self.assertRaises(lock.LockError):
            lock.wait_seconds()
        self.set_env({"PIHX_LOCK_WAIT": "5"})
        self.assertEqual(lock.wait_seconds(), 5)
