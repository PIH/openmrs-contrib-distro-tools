import os
from unittest import mock

from pihx import instance
from pihx.tests.fixtures import TempDirTest, two_service_instance, write


class InstanceTest(TempDirTest):
    def setUp(self):
        super().setUp()
        self.home, self.tools = two_service_instance(self.root)

    def open(self, name="kz"):
        return instance.open(self.home, name, tools=self.tools)

    def test_services_are_the_env_files_present(self):
        kz = self.open()
        self.assertEqual(kz.name, "kz")
        self.assertEqual(kz.dir, self.home / "kz")
        self.assertEqual(kz.tools, self.tools)
        self.assertEqual([s.name for s in kz.services], ["app", "db"])

        (self.home / "kz" / "app.env").unlink()
        self.assertEqual([s.name for s in self.open().services], ["db"])

    def test_unknown_service_env_file_is_an_error(self):
        write(self.home / "kz" / "opnmrs.env", "")
        with self.assertRaises(instance.InstanceError) as raised:
            self.open()
        self.assertIn(str(self.home / "kz" / "opnmrs.env"), str(raised.exception))

    def test_missing_directory_is_an_error(self):
        with self.assertRaises(instance.InstanceError) as raised:
            self.open("nosuch")
        self.assertIn("nosuch", str(raised.exception))

    def test_invalid_names_are_refused(self):
        for name in ["../kz", "Kz", "help", ""]:
            with self.subTest(name=name):
                with self.assertRaises(instance.InstanceError):
                    self.open(name)

    def test_paths_are_absolute_and_tools_unresolved(self):
        link = self.root / "tools-link"
        link.symlink_to(self.tools)
        os.chdir(self.root)
        self.addCleanup(os.chdir, "/")
        kz = instance.open("home", "kz", tools="tools-link")
        self.assertEqual(kz.dir, self.home / "kz")
        self.assertEqual(kz.tools, link)

    def test_pihx_tools_is_required(self):
        env = {k: v for k, v in os.environ.items() if k != "PIHX_TOOLS"}
        with mock.patch.dict(os.environ, env, clear=True):
            with self.assertRaises(instance.InstanceError) as raised:
                instance.open(self.home, "kz")
        self.assertIn("PIHX_TOOLS", str(raised.exception))

    def test_config_expands_as_compose_does(self):
        write(self.home / "kz" / "app.env", "APP_PORT=9090\nAPP_URL=http://${SERVICE_NAME}:$APP_PORT\n"
                                            "APP_DB='$DB_PORT'\nAPP_DB2=\"$DB_PORT \\$x\"\n")
        config = self.open().config()
        self.assertEqual(config["APP_URL"], "http://kz:9090")
        self.assertEqual(config["APP_DB"], "$DB_PORT")
        self.assertEqual(config["APP_DB2"], "3306 $x")

    def test_tools_defaults_to_pihx_tools(self):
        with mock.patch.dict(os.environ, {"PIHX_TOOLS": str(self.tools)}):
            kz = instance.open(self.home, "kz")
        self.assertEqual(kz.tools, self.tools)

    def test_config_precedence(self):
        config = self.open().config()
        self.assertEqual(config["DB_PASSWORD"], "secret $x")   # single-quoted: literal   # db.env beats db's default
        self.assertEqual(config["DB_PORT"], "3306")            # default kept
        self.assertEqual(config["APP_PORT"], "9090")           # app.env beats app's default
        self.assertEqual(config["TZ"], "Africa/Kigali")        # instance.env applies
        self.assertEqual(config["SHARED"], "instance")         # instance.env beats every service

    def test_instance_defaults_come_first(self):
        files = self.open().env_files()
        self.assertEqual(files[0], self.tools / "instance.env.defaults")
        self.assertEqual(files[1], self.tools / "services" / "app" / "env.defaults")

    def test_instance_defaults_apply_below_everything(self):
        (self.home / "kz" / "instance.env").unlink()
        config = self.open().config()
        self.assertEqual(config["TZ"], "UTC")      # instance.env.defaults
        self.assertEqual(config["SHARED"], "db")   # beaten by the services' defaults

    def test_without_instance_env(self):
        (self.home / "kz" / "instance.env").unlink()
        kz = self.open()
        self.assertEqual(kz.config()["SHARED"], "db")  # defaults in service order: app, then db
        self.assertNotIn(self.home / "kz" / "instance.env", kz.env_files())

    def test_bad_env_file_names_the_file(self):
        write(self.home / "kz" / "app.env", "APP_PORT=1\nbroken\n")
        with self.assertRaises(instance.InstanceError) as raised:
            self.open().config()
        self.assertIn(str(self.home / "kz" / "app.env"), str(raised.exception))
        self.assertIn("line 2", str(raised.exception))
