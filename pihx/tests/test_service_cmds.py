import os
import stat

from pihx import instance, lock, services
from pihx.commands import wait
from pihx.tests.fixtures import two_service_instance, write
from pihx.tests.test_instance_cmds import CommandTest, run


def script(path, body):
    write(path, "#!/bin/sh\n" + body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path


class ServiceCommandTest(CommandTest):
    def setUp(self):
        super().setUp()
        self.home, self.tools = two_service_instance(self.root)
        self.set_env({"PIHX_CWD": str(self.root)})
        self.app = self.tools / "services" / "app"

    def inst(self):
        return instance.open(self.home, "kz", tools=self.tools)


class CommandsTest(ServiceCommandTest):
    def test_a_service_lists_its_commands_with_their_descriptions(self):
        script(self.app / "commands" / "hello", "# Says hello\n# more\n")
        script(self.app / "commands" / "bye", "# pihx: no-lock\n# Says bye\n")
        status, out, err = run(["kz", "app"])
        self.assertEqual(status, 0, err)
        self.assertIn("Commands of app:", out)
        self.assertIn("hello", out)
        self.assertIn("Says hello", out)
        self.assertIn("Says bye", out)
        self.assertNotIn("no-lock", out)
        self.assertIn("db has no commands.", run(["kz", "db"])[1])

    def test_a_command_runs_with_the_script_environment_and_its_arguments(self):
        script(self.app / "commands" / "hello",
               'echo "$PIHX_INSTANCE $PIHX_SERVICE $SERVICE_NAME $COMPOSE_PROJECT_NAME $DB_PASSWORD'
               ' $APP_PORT $PIHX_INSTANCE_DIR $PIHX_TOOLS $1 $2"\n')
        # run() captures Python's stdout, not the child's: write where the test can read it.
        out = self.root / "out"
        script(self.app / "commands" / "bye", f'echo "$PIHX_INSTANCE $DB_PASSWORD" > {out}\n')
        status, _, err = run(["kz", "app", "bye"])
        self.assertEqual(status, 0, err)
        self.assertEqual(out.read_text(), "kz secret $x\n")

    def test_the_environment_has_the_instances_values_and_pihx_variables(self):
        env = self.root / "env"
        script(self.app / "commands" / "hello", f'env > {env}\n')
        status, _, err = run(["kz", "app", "hello"])
        self.assertEqual(status, 0, err)
        found = dict(line.split("=", 1) for line in env.read_text().splitlines() if "=" in line)
        self.assertEqual(found["PIHX_INSTANCE"], "kz")
        self.assertEqual(found["PIHX_SERVICE"], "app")
        self.assertEqual(found["SERVICE_NAME"], "kz")
        self.assertEqual(found["COMPOSE_PROJECT_NAME"], "kz")
        self.assertEqual(found["PIHX_INSTANCE_DIR"], str(self.home / "kz"))
        self.assertEqual(found["PIHX_TOOLS"], str(self.tools))
        self.assertEqual(found["APP_PORT"], "9090")
        self.assertEqual(found["TZ"], "Africa/Kigali")
        self.assertIn(str(self.app / "compose.yaml"), found["COMPOSE_FILE"])
        self.assertIn("db.env", found["COMPOSE_ENV_FILES"])

    def test_its_exit_status_is_pihxs(self):
        script(self.app / "commands" / "hello", "exit 7\n")
        self.assertEqual(run(["kz", "app", "hello"])[0], 7)

    def test_arguments_reach_the_command(self):
        out = self.root / "out"
        script(self.app / "commands" / "hello", f'echo "$#:$1:$2" > {out}\n')
        self.assertEqual(run(["kz", "app", "hello", "a b", "--c"])[0], 0)
        self.assertEqual(out.read_text(), "2:a b:--c\n")

    def test_a_command_holds_the_lock_unless_it_says_not_to(self):
        script(self.app / "commands" / "hello", "exit 0\n")
        script(self.app / "commands" / "bye", "# pihx: no-lock\nexit 0\n")
        with lock.hold(self.inst(), 0, command="initialize"):
            status, _, err = run(["kz", "app", "hello"])
            self.assertEqual(status, 1)
            self.assertIn("kz is busy: pihx kz initialize", err)
            self.assertEqual(run(["kz", "app", "bye"])[0], 0)

    def test_the_lock_names_the_command_not_its_arguments(self):
        seen = self.root / "lock"
        script(self.app / "commands" / "hello", f'cat "$PIHX_INSTANCE_DIR/.lock" > {seen}\n')
        run(["kz", "app", "hello", "--password=hunter2"])
        self.assertIn("pihx kz app hello", seen.read_text())
        self.assertNotIn("hunter2", seen.read_text())

    def test_an_unknown_command_a_missing_service_and_an_unknown_word_are_errors(self):
        status, _, err = run(["kz", "app", "nosuch"])
        self.assertEqual((status, "app has no command 'nosuch'" in err), (2, True))
        os.rename(self.home / "kz" / "app.env", self.home / "kz" / "gone")
        status, _, err = run(["kz", "app", "hello"])
        self.assertEqual(status, 1)
        self.assertIn("kz doesn't have the service 'app' (add it: 'pihx kz add-service app')", err)
        status, _, err = run(["kz", "nosuch"])
        self.assertEqual(status, 2)
        self.assertIn("unknown command 'nosuch'", err)

    def test_a_script_that_cant_start_is_an_error_naming_it(self):
        write(self.app / "commands" / "hello", "no shebang, not executable\n")
        status, _, err = run(["kz", "app", "hello"])
        self.assertEqual(status, 1)
        self.assertIn("app hello couldn't run", err)


class SummaryTest(ServiceCommandTest):
    def setUp(self):
        super().setUp()
        script(self.app / "summary.sh", 'echo "[app]"; echo "port $APP_PORT"\n')
        script(self.tools / "services" / "db" / "summary.sh",
               'echo "[db]"; echo "include ${PIHX_SUMMARY_INCLUDE_DISTRIBUTION_ARTIFACTS:-no}"\n')

    def test_sections_come_in_service_order_with_the_required_service_first(self):
        # app sorts first by name, but requires db
        names = [s.name for s in services.in_order(self.inst().services)]
        self.assertEqual(names, ["db", "app"])
        out_file = self.root / "summary.txt"
        status, _, err = run(["kz", "summary", f"--output={out_file}", "--include-distribution-artifacts"])
        self.assertEqual(status, 0, err)
        self.assertEqual(out_file.read_text(), "[db]\ninclude true\n[app]\nport 9090\n")
        self.assertIn(f"Wrote {out_file}.", err)

    def test_without_output_it_prints(self):
        status, out, _ = run(["kz", "summary"])
        self.assertEqual(status, 0)
        self.assertEqual(out, "[db]\ninclude no\n[app]\nport 9090\n")

    def test_a_failing_summary_writes_nothing(self):
        script(self.app / "summary.sh", "echo partial; exit 3\n")
        out_file = self.root / "summary.txt"
        status, out, err = run(["kz", "summary", "--output", str(out_file)])
        self.assertEqual(status, 1)
        self.assertIn("app: summary.sh failed (exit 3); nothing written", err)
        self.assertFalse(out_file.exists())
        self.assertNotIn("partial", out + err)

    def test_options_are_checked(self):
        status, _, err = run(["kz", "summary", "--bogus"])
        self.assertEqual(status, 2)
        self.assertIn("unknown option '--bogus' for summary", err)


class WaitTest(ServiceCommandTest):
    def test_the_timeout_is_a_positive_number_of_seconds(self):
        self.assertEqual(wait.timeout_seconds(), 3600)
        for value in ("soon", "0", "-5", ""):
            with self.subTest(value=value):
                self.set_env({"PIHX_WAIT_TIMEOUT": value})
                with self.assertRaises(wait.CliError):
                    wait.timeout_seconds()
        self.set_env({"PIHX_WAIT_TIMEOUT": "90"})
        self.assertEqual(wait.timeout_seconds(), 90)

    def test_it_takes_no_arguments(self):
        status, _, err = run(["kz", "wait", "now"])
        self.assertEqual(status, 2)
        self.assertIn("unknown option 'now' for wait", err)
