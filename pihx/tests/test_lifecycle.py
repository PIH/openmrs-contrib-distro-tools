import json
import subprocess
from unittest import mock

from pihx import compose, instance, lock
from pihx.commands import lifecycle
from pihx.tests.fixtures import TempDirTest, two_service_instance, write
from pihx.tests.test_instance_cmds import CommandTest, run


def done(stdout="", returncode=0):
    return subprocess.CompletedProcess([], returncode, stdout=stdout, stderr="")


class LifecycleTest(CommandTest):
    """Commands against the fixture checkout (db with a setup, app), Compose and docker faked."""

    def setUp(self):
        super().setUp()
        self.home, self.tools = two_service_instance(self.root)
        self.set_env({})
        self.docker_calls = []
        self.docker_results = {}

    def fake_docker(self, argv, **kwargs):
        self.docker_calls.append(argv[1:])
        for prefix, result in self.docker_results.items():
            if argv[1:1 + len(prefix)] == list(prefix):
                return result
        return done()

    def run_pihx(self, *argv):
        def fake_run(compose_self, *args, **kwargs):
            self.compose_calls.append(args)
            if kwargs.get("stdout") == subprocess.PIPE:
                return done("")
            return done()
        with mock.patch.object(compose.Compose, "run", fake_run), \
                mock.patch.object(lifecycle.subprocess, "run", self.fake_docker):
            return run(list(argv))

    def inst(self):
        return instance.open(self.home, "kz", tools=self.tools)


class CommandsTest(LifecycleTest):
    def test_setup_services_come_from_the_manifests(self):
        self.assertEqual(lifecycle.setup_services(self.inst()), ["db-accounts"])

    def test_update_is_pull_then_up_with_remove_orphans(self):
        status, _, err = self.run_pihx("kz", "update")
        self.assertEqual(status, 0, err)
        self.assertEqual(self.compose_calls[:2], [("pull",), ("up", "-d", "--remove-orphans")])

    def test_update_holds_the_lock_once(self):
        with mock.patch.object(lifecycle.lock, "hold", wraps=lifecycle.lock.hold) as hold:
            self.assertEqual(self.run_pihx("kz", "update")[0], 0)
        self.assertEqual(hold.call_count, 1)

    def test_start_is_up_and_stop_covers_every_profile(self):
        self.run_pihx("kz", "start")
        self.assertEqual(self.compose_calls[0], ("up", "-d"))
        self.compose_calls.clear()
        self.run_pihx("kz", "stop")
        self.assertEqual(self.compose_calls, [("--profile", "*", "down", "--remove-orphans")])

    def test_arguments_are_checked(self):
        for argv in (["start", "--build"], ["stop", "x"], ["logs", "-f"], ["logs", "a", "b"],
                     ["destroy", "--forced"], ["run-service"], ["run-service", "--pull"]):
            with self.subTest(argv=argv):
                status, _, err = self.run_pihx("kz", *argv)
                self.assertEqual(status, 2, err)
                self.assertEqual(self.compose_calls, [])

    def test_changing_commands_refuse_while_the_lock_is_held(self):
        with lock.hold(self.inst(), 0, command="run-service"):
            for command in ("start", "stop", "restart", "pull", "update", "destroy"):
                with self.subTest(command=command):
                    args = ["--force"] if command == "destroy" else []
                    status, _, err = self.run_pihx("kz", command, *args)
                    self.assertEqual(status, 1)
                    self.assertIn("kz is busy: pihx kz run-service", err)
            self.assertEqual(self.compose_calls, [])
            # status and logs only read
            self.assertEqual(self.run_pihx("kz", "status")[0], 0)
            status, out, _ = self.run_pihx("kz", "status")
            self.assertIn("Busy: pihx kz run-service", out)
            self.assertEqual(self.run_pihx("kz", "logs")[0], 0)


class SetupChecksTest(LifecycleTest):
    def test_a_failed_setup_is_named_with_its_log(self):
        def fake_run(compose_self, *args, **kwargs):
            return done("abc123\n" if args[:1] == ("ps",) else "")
        self.docker_results = {("wait",): done("3\n")}
        with mock.patch.object(compose.Compose, "run", fake_run), \
                mock.patch.object(lifecycle.subprocess, "run", self.fake_docker):
            with self.assertRaises(lifecycle.CliError) as caught:
                lifecycle.check_setup_services(self.inst(), compose.Compose(self.inst()))
        self.assertEqual(str(caught.exception),
                         "db-accounts failed (exit 3; above, or 'pihx kz logs db-accounts')")
        self.assertIn(["logs", "--tail", "20", "abc123"], self.docker_calls)

    def test_an_empty_docker_wait_is_its_own_error(self):
        def fake_run(compose_self, *args, **kwargs):
            return done("abc123\n" if args[:1] == ("ps",) else "")
        self.docker_results = {("wait",): done("")}
        with mock.patch.object(compose.Compose, "run", fake_run), \
                mock.patch.object(lifecycle.subprocess, "run", self.fake_docker):
            with self.assertRaises(lifecycle.CliError) as caught:
                lifecycle.check_setup_services(self.inst(), compose.Compose(self.inst()))
        self.assertIn("couldn't wait for db-accounts", str(caught.exception))

    def test_a_setup_that_has_no_container_is_skipped(self):
        with mock.patch.object(compose.Compose, "run", lambda *a, **k: done("")), \
                mock.patch.object(lifecycle.subprocess, "run", self.fake_docker):
            lifecycle.check_setup_services(self.inst(), compose.Compose(self.inst()))
        self.assertEqual(self.docker_calls, [])


class ReplacedImagesTest(LifecycleTest):
    def remove_replaced(self, before, after, tags, digests):
        def fake(argv, **kwargs):
            self.docker_calls.append(argv[1:])
            if argv[1:3] == ["ps", "-aq"]:
                return done("c1\n")
            if argv[1] == "inspect":
                return done("\n".join(after))
            if argv[1:3] == ["image", "inspect"]:
                return done(tags if "RepoTags" in argv[4] else digests)
            return done()
        with mock.patch.object(lifecycle.subprocess, "run", fake):
            lifecycle.remove_replaced_images(self.inst(), compose.Compose(self.inst()), before)
        return [c for c in self.docker_calls if c[:2] == ["image", "rm"]]

    def test_an_image_still_used_is_kept(self):
        self.assertEqual(self.remove_replaced({"sha256:a"}, ["sha256:a"], "", ""), [])

    def test_an_untagged_image_is_removed(self):
        self.assertEqual(self.remove_replaced({"sha256:a"}, ["sha256:b"], "", ""),
                         [["image", "rm", "sha256:a"]])

    def test_a_pulled_image_is_removed_and_a_tagged_local_build_kept(self):
        self.assertEqual(self.remove_replaced({"sha256:a"}, ["sha256:b"], "x:1", "x@sha256:1"),
                         [["image", "rm", "sha256:a"]])
        self.docker_calls.clear()
        self.assertEqual(self.remove_replaced({"sha256:a"}, ["sha256:b"], "x:1", ""), [])


class DestroyTest(LifecycleTest):
    def test_anything_but_y_leaves_the_instance(self):
        for answer in ("n", "", "yes please", "N"):
            with self.subTest(answer=answer), mock.patch("builtins.input", return_value=answer):
                status, out, _ = self.run_pihx("kz", "destroy")
                self.assertEqual(status, 0)
                self.assertIn("This will stop the stack", out)
                self.assertTrue((self.home / "kz").is_dir())
        self.assertEqual(self.compose_calls, [])

    def test_a_directory_without_instance_env_is_refused(self):
        (self.home / "kz" / "instance.env").unlink()
        (self.home / "user").mkdir()
        for name in ("kz", "user"):
            with self.subTest(name=name):
                status, _, err = self.run_pihx(name, "destroy", "--force")
                self.assertEqual(status, 1)
                self.assertIn(f"{self.home / name} has no instance.env, so it isn't an instance",
                              err)
                self.assertTrue((self.home / name).is_dir())
        self.assertTrue((self.home / "kz" / "db.env").is_file())
        self.assertEqual(self.compose_calls, [])
        self.assertEqual(self.docker_calls, [])

    def test_eof_at_the_prompt_leaves_the_instance(self):
        with mock.patch("builtins.input", side_effect=EOFError):
            self.assertEqual(self.run_pihx("kz", "destroy")[0], 0)
        self.assertTrue((self.home / "kz").is_dir())

    def test_force_removes_volumes_and_the_directory_but_not_a_tools_link(self):
        (self.home / "kz" / "tools").symlink_to(self.tools)
        # Volumes only the restore overlays declare go too.
        write(self.tools / "services" / "db" / "restore" / "dump.yaml",
              "volumes:\n  db-init:\n  percona-staging:\n")
        status, out, err = self.run_pihx("kz", "destroy", "--force")
        self.assertEqual(status, 0, err)
        self.assertEqual(self.compose_calls, [("--profile", "*", "down", "-v", "--remove-orphans")])
        self.assertIn(["volume", "rm", "kz_db-init", "kz_percona-staging"], self.docker_calls)
        self.assertFalse((self.home / "kz").exists())
        self.assertTrue((self.tools / "services").is_dir())

    def test_a_tools_directory_is_kept(self):
        (self.home / "kz" / "tools").mkdir()
        status, _, err = self.run_pihx("kz", "destroy", "--force")
        self.assertEqual(status, 0, err)
        self.assertEqual([p.name for p in (self.home / "kz").iterdir()], ["tools"])

    def test_a_symlinked_instance_directory_is_only_unlinked(self):
        real = self.root / "real"
        (self.home / "kz").rename(real)
        (self.home / "kz").symlink_to(real)
        status, _, err = self.run_pihx("kz", "destroy", "--force")
        self.assertEqual(status, 0, err)
        self.assertFalse((self.home / "kz").is_symlink())
        self.assertTrue((real / "db.env").is_file())

    def test_root_owned_files_are_reclaimed_without_touching_a_kept_tools_directory(self):
        (self.home / "kz" / "tools").mkdir()
        (self.home / "kz" / "out").mkdir()
        write(self.tools / "utils" / "lib" / "images.sh", "ALPINE_IMAGE=alpine:3.21\n")
        original = lifecycle.shutil.rmtree
        calls = []

        def rmtree(path, *a, **k):
            if not calls:
                calls.append(path)
                raise PermissionError("root-owned")
            return original(path, *a, **k)
        with mock.patch.object(lifecycle.shutil, "rmtree", rmtree):
            status, _, err = self.run_pihx("kz", "destroy", "--force")
        self.assertEqual(status, 0, err)
        chown = next(c for c in self.docker_calls if c[:1] == ["run"])
        self.assertIn("find", chown)
        self.assertIn("tools", chown)
        self.assertEqual(chown[chown.index("alpine:3.21") + 1:][:2], ["find", "/target"])
        self.assertEqual(chown.count("/target"), 1)
        self.assertEqual([p.name for p in (self.home / "kz").iterdir()], ["tools"])

    def test_a_removal_that_still_fails_is_an_error_line(self):
        (self.home / "kz" / "out").mkdir()
        write(self.tools / "utils" / "lib" / "images.sh", "ALPINE_IMAGE=alpine:3.21\n")
        with mock.patch.object(lifecycle.shutil, "rmtree", side_effect=PermissionError("denied")):
            status, _, err = self.run_pihx("kz", "destroy", "--force")
        self.assertEqual(status, 1)
        self.assertIn("error: couldn't remove", err)

    def test_a_failed_down_falls_back_to_the_project_label(self):
        def fake_run(compose_self, *args, **kwargs):
            return done(returncode=1)
        self.docker_results = {("ps",): done("c1\nc2\n"), ("volume", "ls"): done("v1\n")}
        with mock.patch.object(compose.Compose, "run", fake_run), \
                mock.patch.object(lifecycle.subprocess, "run", self.fake_docker):
            status, _, err = run(["kz", "destroy", "--force"])
        self.assertEqual(status, 0, err)
        self.assertIn(["rm", "-f", "c1", "c2"], self.docker_calls)
        self.assertIn(["volume", "rm", "v1"], self.docker_calls)
        self.assertFalse((self.home / "kz").exists())

    def test_a_failed_listing_in_the_fallback_removes_nothing(self):
        def fake_run(compose_self, *args, **kwargs):
            return done(returncode=1)
        for failing in (("ps",), ("volume", "ls")):
            with self.subTest(failing=failing):
                self.docker_calls.clear()
                self.docker_results = {("ps",): done("c1\n"), ("volume", "ls"): done("v1\n"),
                                       failing: done(returncode=1)}
                with mock.patch.object(compose.Compose, "run", fake_run), \
                        mock.patch.object(lifecycle.subprocess, "run", self.fake_docker):
                    status, _, err = run(["kz", "destroy", "--force"])
                self.assertEqual(status, 1)
                self.assertIn("nothing was removed", err)
                self.assertEqual([c for c in self.docker_calls if "rm" in c], [])
                self.assertTrue((self.home / "kz" / "instance.env").is_file())

    def test_an_unknown_instance_is_an_error(self):
        status, _, err = self.run_pihx("nope", "destroy", "--force")
        self.assertEqual(status, 2)
        self.assertIn("no instance 'nope'", err)


class RunServiceTest(LifecycleTest):
    # app is profiled (one-shot); db runs with the instance.
    CONFIG = json.dumps({"services": {"app": {"profiles": ["app"]}, "db": {}}})

    def run_service(self, *args, defined=CONFIG):
        def fake_run(compose_self, *a, **kwargs):
            self.compose_calls.append(a)
            return done(defined) if kwargs.get("stdout") == subprocess.PIPE else done()
        with mock.patch.object(compose.Compose, "run", fake_run), \
                mock.patch.object(lifecycle.subprocess, "run", self.fake_docker):
            return run(["kz", "run-service", *args])

    def test_a_signal_death_is_128_plus_the_signal(self):
        def fake_run(compose_self, *a, **kwargs):
            if kwargs.get("stdout") == subprocess.PIPE:
                return done(self.CONFIG)
            return done(returncode=-9)
        with mock.patch.object(compose.Compose, "run", fake_run):
            self.assertEqual(run(["kz", "run-service", "app", "x"])[0], 137)

    def test_an_unknown_service_is_refused(self):
        status, _, err = self.run_service("nope")
        self.assertEqual(status, 1)
        self.assertIn("nope not present on kz (run 'add-service nope' first)", err)

    def test_a_service_that_is_not_a_job_runs_once_and_only_checks_the_lock(self):
        with lock.hold(self.inst(), 0, command="update"):
            status, _, err = self.run_service("app", "echo", "hi")
        self.assertEqual(status, 1)
        self.assertIn("busy", err)
        status, _, err = self.run_service("--pull", "app", "echo", "hi")
        self.assertEqual(status, 0, err)
        self.assertIn(("pull", "app"), self.compose_calls)
        self.assertIn(("run", "--rm", "--no-deps", "app", "echo", "hi"), self.compose_calls)

    def test_a_service_that_runs_with_the_instance_is_refused(self):
        status, _, err = self.run_service("db", "sh")
        self.assertEqual(status, 2)
        self.assertIn("db runs with the instance, so run-service won't start another one", err)
        self.assertIn("(app)", err)
        self.assertIn("pihx kz compose exec db", err)
        self.assertFalse([c for c in self.compose_calls if "run" in c or "up" in c])

    def test_a_job_runs_even_without_a_profile(self):
        manifest = self.tools / "services" / "app" / "service.yaml"
        manifest.write_text(manifest.read_text().replace("job: false", "job: true"))
        status, _, err = self.run_service("app", defined=json.dumps({"services": {"app": {}}}))
        self.assertNotIn("runs with the instance", err)
        self.assertIn(("up", "--no-start", "--no-deps", "app"), self.compose_calls)


class StartLockedTest(LifecycleTest):
    def test__start_is_start_without_the_lock_for_commands_that_hold_it(self):
        status, _, err = self.run_pihx("kz", "_start")
        self.assertEqual(status, 2)
        self.assertIn("use 'start'", err)
        self.assertEqual(self.compose_calls, [])
        # The variable alone isn't enough: the lock must be held.
        self.set_env({lifecycle.LOCK_HELD: "kz"})
        status, _, err = self.run_pihx("kz", "_start")
        self.assertEqual(status, 2)
        self.assertIn("use 'start'", err)
        self.assertEqual(self.compose_calls, [])
        with lock.hold(self.inst(), 0, command="x"):
            status, _, err = self.run_pihx("kz", "_start")
        self.assertEqual(status, 0, err)
        self.assertEqual(self.compose_calls[0], ("up", "-d"))


class StartEnvTest(LifecycleTest):
    """start-env scripts' values reach that start's `up` only, and only those their manifest entry
    declares; a failed or malformed one gives its declared values empty, so the compose file's
    (safe) default applies."""

    def setUp(self):
        super().setUp()
        write(self.tools / "services" / "app" / "start" / "values", "")
        manifest = self.tools / "services" / "app" / "service.yaml"
        manifest.write_text(manifest.read_text() + "start-env:\n  - script: start/values\n"
                            "    sets: [APP_FOUND, APP_OTHER]\n")
        self.up_env = []

    def start(self, command, stdout="", returncode=0):
        def fake_run(compose_self, *args, **kwargs):
            if args[:1] == ("up",):
                self.up_env.append(compose_self.environment())
            return done("")
        script_calls = []

        def fake_script(inst, path, **kwargs):
            script_calls.append((path, kwargs))
            return done(stdout, returncode)
        with mock.patch.object(compose.Compose, "run", fake_run), \
                mock.patch.object(lifecycle.subprocess, "run", self.fake_docker), \
                mock.patch.object(lifecycle.script, "run", fake_script):
            result = run(["kz", command])
        self.assertEqual(len(script_calls), 1)
        self.assertEqual(script_calls[0][0], self.tools / "services" / "app" / "start" / "values")
        return result

    def declared(self):
        return {k: self.up_env[0].get(k) for k in ("APP_FOUND", "APP_OTHER")}

    def test_start_and_update_pass_the_values_to_up(self):
        for command in ("start", "update"):
            with self.subTest(command=command):
                self.up_env.clear()
                status, _, err = self.start(command, "APP_FOUND=true\n\n")
                self.assertEqual(status, 0, err)
                # A declared variable it didn't print is passed empty.
                self.assertEqual(self.declared(), {"APP_FOUND": "true", "APP_OTHER": ""})

    def test_only_declared_variables_are_set_and_never_pihx_own(self):
        self.set_env({"PATH": "/usr/bin"})
        status, _, err = self.start("start", "APP_FOUND=true\nAPP_STRAY=x\nPATH=/evil\n"
                                    "PIHX_TOOLS=/evil\nCOMPOSE_FILE=/evil\nSERVICE_NAME=evil\n")
        self.assertEqual(status, 0, err)
        self.assertEqual(self.declared(), {"APP_FOUND": "true", "APP_OTHER": ""})
        env = self.up_env[0]
        self.assertNotIn("APP_STRAY", env)
        self.assertEqual(env["PATH"], "/usr/bin")
        self.assertEqual(env["PIHX_TOOLS"], str(self.tools))
        self.assertEqual(env["SERVICE_NAME"], "kz")
        self.assertNotIn("/evil", env["COMPOSE_FILE"])
        for name in ("APP_STRAY", "PATH", "PIHX_TOOLS", "COMPOSE_FILE", "SERVICE_NAME"):
            self.assertIn(f"warning: app: start/values printed {name}, which its manifest doesn't "
                          "let it set; ignored", err)
        self.assertNotIn("/evil", err)

    def test_a_failed_script_gives_its_variables_empty(self):
        status, _, err = self.start("start", "APP_FOUND=true\n", returncode=1)
        self.assertEqual(status, 0, err)
        self.assertIn("warning: app: start/values failed (exit 1); starting with APP_FOUND, "
                      "APP_OTHER empty", err)
        self.assertEqual(self.declared(), {"APP_FOUND": "", "APP_OTHER": ""})

    def test_a_malformed_line_gives_its_variables_empty_and_is_not_shown(self):
        status, _, err = self.start("start", "APP_FOUND=true\nsecret-ish words\n")
        self.assertEqual(status, 0, err)
        self.assertIn("printed a malformed line", err)
        self.assertNotIn("secret-ish", err)
        self.assertEqual(self.declared(), {"APP_FOUND": "", "APP_OTHER": ""})


class ComposeCommandTest(LifecycleTest):
    """`compose` runs docker compose with pihx's own options, the arguments untouched, and no lock."""

    def run_compose(self, *args, returncode=0):
        calls = []

        def fake_run(argv, **kwargs):
            calls.append((argv, kwargs))
            return done("", returncode)
        with mock.patch.object(compose.subprocess, "run", fake_run), \
                mock.patch.object(lifecycle.lock, "hold") as hold:
            result = run(["kz", "compose", *args])
        hold.assert_not_called()
        return result, calls

    def test_argv_is_docker_compose_pihx_options_then_the_arguments(self):
        (status, _, err), calls = self.run_compose("exec", "-T", "app", "sh", "-c", "echo $X")
        self.assertEqual(status, 0, err)
        self.assertEqual(len(calls), 1)
        argv, kwargs = calls[0]
        self.assertEqual(argv, ["docker", "compose", *compose.Compose(self.inst()).args(),
                                "exec", "-T", "app", "sh", "-c", "echo $X"])
        # Output and input are the caller's.
        self.assertNotIn("stdout", kwargs)
        self.assertNotIn("stdin", kwargs)
        self.assertEqual(kwargs["env"]["COMPOSE_PROJECT_NAME"], "kz")

    def test_exit_status_is_composes(self):
        (status, _, _), _ = self.run_compose("config", returncode=3)
        self.assertEqual(status, 3)

    def test_start_env_variables_are_passed_empty(self):
        write(self.tools / "services" / "app" / "start" / "values", "")
        manifest = self.tools / "services" / "app" / "service.yaml"
        manifest.write_text(manifest.read_text() + "start-env:\n  - script: start/values\n"
                            "    sets: [APP_FOUND, APP_OTHER]\n")
        _, calls = self.run_compose("config")
        env = calls[0][1]["env"]
        self.assertEqual((env["APP_FOUND"], env["APP_OTHER"]), ("", ""))

    def test_inspecting_subcommands_run(self):
        for sub in lifecycle.COMPOSE_INSPECT:
            with self.subTest(sub=sub):
                (status, _, err), calls = self.run_compose(sub, "--x", "y")
                self.assertEqual(status, 0, err)
                self.assertEqual(calls[0][0][-3:], [sub, "--x", "y"])

    def test_changing_subcommands_are_refused_with_the_managed_command_and_docker_not_run(self):
        pointers = {"down": "pihx kz stop", "stop": "pihx kz stop", "up": "pihx kz start",
                    "start": "pihx kz start", "restart": "pihx kz restart", "pull": "pihx kz pull",
                    "run": "pihx kz run-service", "rm": "pihx kz remove-service",
                    "create": "pihx kz start", "kill": "only inspects", "build": "only inspects",
                    "cp": "only inspects", "nonsense": "only inspects"}
        for sub, pointer in pointers.items():
            with self.subTest(sub=sub):
                (status, _, err), calls = self.run_compose(sub, "x")
                self.assertEqual(status, 2)
                self.assertTrue(err.startswith("error: "), err)
                self.assertIn(pointer, err)
                self.assertEqual(calls, [])

    def test_a_leading_option_or_no_subcommand_is_refused(self):
        for args in (["-f", "x.yaml", "config"], ["--dry-run", "ps"], []):
            with self.subTest(args=args):
                (status, _, err), calls = self.run_compose(*args)
                self.assertEqual(status, 2)
                self.assertIn("usage: pihx kz compose", err)
                self.assertEqual(calls, [])
