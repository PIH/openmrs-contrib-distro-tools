"""The OpenMRS front end, against this checkout's own services, with Docker Compose faked."""

import contextlib
import io
import os
import subprocess
from pathlib import Path
from unittest import mock

from openmrs import front
from pihx import compose
from pihx.commands import CliError, initialize, lifecycle
from pihx.tests.fixtures import write
from pihx.tests.test_instance_cmds import CommandTest

TOOLS = Path(__file__).resolve().parents[2]


class FrontTest(CommandTest):
    def setUp(self):
        super().setUp()
        self.tools = TOOLS
        self.set_env({})

    def front(self, *argv):
        """Runs the front end; returns (status, stdout, stderr)."""
        out, err = io.StringIO(), io.StringIO()

        def fake_run(compose_self, *args, **kwargs):
            self.compose_calls.append((args, [str(f) for f in compose_self.extra_files],
                                       dict(compose_self.extra_env)))
            return subprocess.CompletedProcess([], 0, stdout="")
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), \
                mock.patch.object(compose.Compose, "run", fake_run):
            status = front.main(list(argv))
        return status, out.getvalue(), err.getvalue()

    def make(self, name="kz", services=("openmrs-db", "openmrs"), **files):
        """An instance directory as create leaves it, with <files> ({stem: text})."""
        for svc in services:
            write(self.home / name / f"{svc}.env", files.pop(svc, ""))
        write(self.home / name / "instance.env", files.pop("instance", ""))
        return self.home / name


class CreateTest(FrontTest):
    def test_the_default_services_and_front_end_values_in_instance_env(self):
        self.set_env({"OPENMRS_IMAGE_NAME": "pih/emr", "DISTRO_SOURCE_DIR": "/src/distro",
                      "SEED_IMAGE_NAME": "pih/seed", "TZ": "Africa/Maseru"})
        status, _, err = self.front("kz", "create")
        self.assertEqual(status, 0, err)
        self.assertEqual(sorted(p.name for p in (self.home / "kz").glob("*.env")),
                         ["instance.env", "openmrs-db.env", "openmrs.env"])
        self.assertEqual(self.read("kz", "instance.env"),
                         "TZ='Africa/Maseru'\nDISTRO_SOURCE_DIR='/src/distro'\n"
                         "SEED_IMAGE_NAME='pih/seed'\n")
        self.assertEqual(self.read("kz", "openmrs.env"), "OPENMRS_IMAGE_NAME='pih/emr'\n")

    def test_services_from_SERVICES(self):
        self.set_env({"SERVICES": "openmrs-db"})
        status, _, err = self.front("kz", "create")
        self.assertEqual(status, 0, err)
        self.assertEqual(sorted(p.name for p in (self.home / "kz").glob("*.env")),
                         ["instance.env", "openmrs-db.env"])

    def test_openmrs_needs_its_image(self):
        status, _, err = self.front("kz", "create")
        self.assertEqual(status, 1)
        self.assertIn("OPENMRS_IMAGE_NAME must be set", err)
        self.assertFalse((self.home / "kz").exists())

    def test_a_front_end_value_an_env_file_can_t_hold_leaves_nothing(self):
        self.set_env({"SERVICES": "openmrs-db", "SEED_IMAGE_NAME": "it's"})
        status, _, err = self.front("kz", "create")
        self.assertEqual(status, 1)
        self.assertIn("SEED_IMAGE_NAME contains a single quote", err)
        self.assertFalse((self.home / "kz").exists())

    def test_a_bad_name_and_arguments(self):
        status, _, err = self.front("Bad", "create")
        self.assertEqual(status, 2)
        self.assertIn("must be lowercase letters, digits, '-' and '_'", err)
        status, _, err = self.front("kz", "create", "extra")
        self.assertEqual(status, 2)
        self.assertIn("usage: openmrs-docker create <name>", err)


class CommandLineTest(FrontTest):
    def test_list_prints_only_names(self):
        self.make("one")
        (self.home / "not-one").mkdir()
        status, out, _ = self.front("list")
        self.assertEqual((status, out), (0, "one\n"))

    def test_a_missing_instance_and_an_unknown_command(self):
        status, _, err = self.front("kz", "status")
        self.assertEqual(status, 2)
        self.assertIn("no instance found at", err)
        self.assertIn("openmrs-docker create kz", err)
        self.make()
        status, _, err = self.front("kz", "frobnicate")
        self.assertEqual(status, 2)
        self.assertIn("unknown command 'frobnicate'", err)

    def test_sync_says_it_isn_t_needed(self):
        self.make()
        status, out, _ = self.front("kz", "sync")
        self.assertEqual(status, 0)
        self.assertIn("sync is no longer needed", out)
        self.assertEqual(self.compose_calls, [])

    def test_options_a_command_doesn_t_take(self):
        self.make()
        for argv, message in [(("stop", "--force"), "unknown option '--force' for stop"),
                              (("destroy", "--dev"), "unknown option '--dev' for destroy"),
                              (("start", "--force"), "unknown option '--force' for start"),
                              (("build", "--dev"), "unknown option '--dev' for build"),
                              (("fingerprint", "--bogus"), "unknown option '--bogus' for fingerprint")]:
            with self.subTest(argv=argv):
                status, _, err = self.front("kz", *argv)
                self.assertEqual(status, 2)
                self.assertIn(message, err)


class ModesTest(FrontTest):
    def test_dev_and_build_add_their_overlays(self):
        self.make(instance="DISTRO_SOURCE_DIR='/src/distro'\n")
        modes = TOOLS / "openmrs" / "modes"
        with mock.patch.object(lifecycle, "instance_images", return_value=set()):
            status, _, err = self.front("kz", "start", "--dev", "--build")
        self.assertEqual(status, 0, err)
        self.assertEqual(self.compose_calls[0][0], ("build",))
        self.assertEqual(self.compose_calls[0][1], [str(modes / "dev.yaml"),
                                                    str(modes / "build.yaml")])
        self.assertEqual(self.compose_calls[1][0], ("up", "-d"))

    def test_update_pulls_then_builds(self):
        self.make(instance="DISTRO_SOURCE_DIR='/src/distro'\n")
        with mock.patch.object(lifecycle, "instance_images", return_value=set()):
            status, _, err = self.front("kz", "update", "--build")
        self.assertEqual(status, 0, err)
        self.assertEqual([c[0][0] for c in self.compose_calls][:3], ["pull", "build", "up"])

    def test_dev_build_and_the_build_command_need_DISTRO_SOURCE_DIR(self):
        self.make()
        for argv in (("start", "--dev"), ("update", "--build"), ("build",),
                     ("_distro-source-dir",)):
            with self.subTest(argv=argv):
                status, _, err = self.front("kz", *argv)
                self.assertEqual(status, 1)
                self.assertIn("DISTRO_SOURCE_DIR must be set in", err)
        self.assertEqual(self.compose_calls, [])

    def test_distro_source_dir_is_the_instance_s_not_the_caller_s(self):
        self.make(instance="DISTRO_SOURCE_DIR='/src/distro'\n")
        self.set_env({"DISTRO_SOURCE_DIR": "/elsewhere"})
        status, out, _ = self.front("kz", "_distro-source-dir")
        self.assertEqual((status, out), (0, "/src/distro\n"))


class RunServiceTest(FrontTest):
    def test_the_caller_s_values_for_the_service_s_own_unset_variables(self):
        self.make(services=("openmrs-db", "openmrs", "openmrs-smoke-tests"),
                  **{"openmrs-smoke-tests": "SMOKE_TESTS_IMAGE_TAG='pinned'\n"})
        self.set_env({"SMOKE_TESTS_ADMIN_PASSWORD": "pw", "SMOKE_TESTS_IMAGE_TAG": "other",
                      "OPENMRS_DB_PASSWORD": "not-passed"})
        with mock.patch.object(lifecycle, "cmd_run_service", return_value=0) as run:
            status, _, err = self.front("kz", "run-service", "--pull", "openmrs-smoke-tests", "x")
        self.assertEqual(status, 0, err)
        run.assert_called_once_with("kz", ["--pull", "openmrs-smoke-tests", "x"],
                                    extra_env={"SMOKE_TESTS_ADMIN_PASSWORD": "pw"})


class FingerprintTest(FrontTest):
    def fingerprint(self, *args):
        with mock.patch("pihx.commands.summary.summarize", return_value="[s]\n") as summarize:
            result = self.front("kz", "fingerprint", *args)
        return result, summarize

    def test_the_database_only_by_default(self):
        self.make()
        (status, out, _), summarize = self.fingerprint()
        self.assertEqual((status, out), (0, "[s]\n"))
        _, services = summarize.call_args[0][:2]
        self.assertEqual([s.name for s in services], ["openmrs-db"])
        self.assertEqual(summarize.call_args[1], {"include": False})

    def test_data_dir_with_or_without_the_distribution_artifacts(self):
        self.make()
        for args, include in ((("--data-dir",), True),
                              (("--data-dir", "--exclude-distribution-artifacts"), False)):
            with self.subTest(args=args):
                (status, _, err), summarize = self.fingerprint(*args)
                self.assertEqual(status, 0, err)
                self.assertEqual([s.name for s in summarize.call_args[0][1]],
                                 ["openmrs-db", "openmrs"])
                self.assertEqual(summarize.call_args[1], {"include": include})

    def test_output_is_written_to_the_file(self):
        self.make()
        (status, _, err), _ = self.fingerprint(f"--output={self.root / 'f.txt'}")
        self.assertEqual(status, 0, err)
        self.assertEqual((self.root / "f.txt").read_text(), "[s]\n")

    def test_needs_openmrs_db(self):
        self.make(services=("openhim",))
        (status, _, err), _ = self.fingerprint()
        self.assertEqual(status, 1)
        self.assertIn("kz has no openmrs-db service", err)

    def test_reset_openmrs_db_accounts_needs_openmrs_db(self):
        self.make(services=("openhim",))
        status, _, err = self.front("kz", "reset-openmrs-db-accounts")
        self.assertEqual(status, 1)
        self.assertIn("kz has no openmrs-db service", err)


class RestoreEntriesTest(FrontTest):
    def given(self, **paths):
        """Sets each RESTORE_* variable to its value as typed, and to a real path in the temp dir
        as the launcher resolves it (a directory if the value ends with /, else a file); None
        leaves it unresolved, as for a path that doesn't exist."""
        environ = {}
        for variable, value in paths.items():
            if value is None:
                continue
            typed, _, kind = value.partition("|")
            environ[variable] = typed
            if kind == "missing":
                continue
            path = self.root / "src" / variable / typed.rstrip("/")
            if kind == "dir":
                path.mkdir(parents=True)
            else:
                write(path, "x")
            environ[front.RESOLVED_PREFIX + variable] = str(path)
        self.set_env(environ)

    def test_names(self):
        cases = [
            ({"RESTORE_MYSQL_DUMP_PATH": "d.sql"}, "openmrs-db.sql"),
            ({"RESTORE_MYSQL_DUMP_PATH": "d.sql.gz"}, "openmrs-db.sql.gz"),
            ({"RESTORE_MYSQL_DUMP_PATH": "d.7z"}, "openmrs-db.sql.7z"),
            ({"RESTORE_MYSQL_DUMP_PATH": "d.zip"}, "openmrs-db.sql.zip"),
            ({"RESTORE_MYSQL_DATA_PATH": "mysql|dir"}, "openmrs-db.datadir"),
            ({"RESTORE_MYSQL_PERCONA_PATH": "p|dir"}, "openmrs-db.percona"),
            ({"RESTORE_MYSQL_PERCONA_PATH": "p.tgz"}, "openmrs-db.percona.tgz"),
            ({"RESTORE_OPENMRS_DATA_PATH": "data|dir"}, "openmrs"),
            ({"RESTORE_OPENMRS_DATA_PATH": "data.tar.gz"}, "openmrs.tar.gz"),
            ({"RESTORE_OPENMRS_DATA_PATH": "data.7z"}, "openmrs.7z"),
        ]
        for paths, entry in cases:
            with self.subTest(paths=paths):
                self.given(**paths)
                self.assertEqual(list(front.restore_entries()), [entry])

    def test_every_name_is_one_its_service_accepts(self):
        accepted = {n.rstrip("/") for svc in ("openmrs-db", "openmrs")
                    for r in front.services_module.load(TOOLS, svc).manifest.restore
                    for n in r.names}
        for ext in ("sql", "sql.gz", "sql.7z", "sql.zip", "datadir", "percona"):
            self.assertIn(f"openmrs-db.{ext}", accepted)
        for ext in front.PERCONA_ARCHIVES:
            self.assertIn(f"openmrs-db.percona.{ext}", accepted)
        for ext in front.DATA_ARCHIVES:
            self.assertIn(f"openmrs.{ext}", accepted)
        self.assertIn("openmrs", accepted)

    def test_errors_name_the_path_as_typed(self):
        cases = [
            ({"RESTORE_MYSQL_DUMP_PATH": "nope.sql|missing"}, "no such file: nope.sql"),
            ({"RESTORE_MYSQL_DUMP_PATH": "dir.sql|dir"}, "no such file: dir.sql"),
            ({"RESTORE_MYSQL_DATA_PATH": "nope|missing"}, "no such directory: nope"),
            ({"RESTORE_MYSQL_DATA_PATH": "file"}, "no such directory: file"),
            ({"RESTORE_MYSQL_PERCONA_PATH": "p|missing"}, "no such file or directory: p"),
            ({"RESTORE_MYSQL_PERCONA_PATH": "p.rar"},
             "must be a directory or a .7z/.zip/.tar.gz/.tgz/.tar archive: p.rar"),
            ({"RESTORE_OPENMRS_DATA_PATH": "x.tar.gz|missing"},
             "no such file or directory: x.tar.gz"),
            ({"RESTORE_OPENMRS_DATA_PATH": "data.rar"},
             "must be a directory or a .tar.gz/.tgz/.tar/.7z/.zip archive: data.rar"),
            ({"RESTORE_MYSQL_DUMP_PATH": "d.sql", "RESTORE_MYSQL_DATA_PATH": "m|dir"},
             "set exactly one of"),
        ]
        for paths, message in cases:
            with self.subTest(paths=paths):
                self.given(**paths)
                with self.assertRaises(CliError) as raised:
                    front.restore_entries()
                self.assertIn(message, str(raised.exception))

    def test_entries_are_links_to_the_host_paths_or_copies(self):
        source = write(self.root / "src" / "d.sql", "dump")
        folder = self.root / "folder"
        folder.mkdir()
        front.add_entries(folder, {"openmrs-db.sql": str(source)})
        self.assertEqual(os.readlink(folder / "openmrs-db.sql"), str(source))
        other = self.root / "other"
        other.mkdir()
        with mock.patch.object(front.os, "symlink", side_effect=OSError("no links here")):
            front.add_entries(other, {"openmrs-db.sql": str(source)})
        self.assertFalse((other / "openmrs-db.sql").is_symlink())
        self.assertEqual((other / "openmrs-db.sql").read_text(), "dump")


class InitializeTest(FrontTest):
    def initialize(self, **environ):
        """Runs initialize with <environ>; returns (status, err, [(how, folder entries, image)])."""
        self.set_env(environ)
        calls = []

        def restore_folder(inst, folder, label=None):
            calls.append(("folder", sorted(os.listdir(folder)), None))

        def restore_image(inst, image, adjust=None):
            folder = self.root / "seed"
            folder.mkdir(exist_ok=True)
            for entry in ("openmrs-db.sql.gz", "openmrs.tar.gz"):
                write(folder / entry, "")
            adjust(folder)
            calls.append(("image", sorted(os.listdir(folder)), image))

        with mock.patch.object(initialize, "restore_folder", restore_folder), \
                mock.patch.object(initialize, "restore_image", restore_image):
            status, _, err = self.front("kz", "initialize")
        return status, err, calls

    def dump(self):
        path = write(self.root / "d.sql", "")
        return {"RESTORE_MYSQL_DUMP_PATH": "d.sql",
                front.RESOLVED_PREFIX + "RESTORE_MYSQL_DUMP_PATH": str(path)}

    def data(self):
        path = self.root / "data"
        path.mkdir()
        return {"RESTORE_OPENMRS_DATA_PATH": "data",
                front.RESOLVED_PREFIX + "RESTORE_OPENMRS_DATA_PATH": str(path)}

    def test_restore_paths_alone_make_a_folder(self):
        self.make()
        status, err, calls = self.initialize(**self.dump(), **self.data())
        self.assertEqual(status, 0, err)
        self.assertEqual(calls, [("folder", ["openmrs", "openmrs-db.sql"], None)])
        self.assertEqual([p for p in self.home.iterdir() if p.name.startswith(".")], [])

    def test_the_seed_gives_what_no_restore_path_does(self):
        self.make(instance="SEED_IMAGE_NAME='pih/seed'\nSEED_IMAGE_TAG='v1'\n")
        status, err, calls = self.initialize(**self.dump())
        self.assertEqual(status, 0, err)
        self.assertEqual(calls, [("image", ["openmrs-db.sql", "openmrs.tar.gz"], "pih/seed:v1")])

    def test_the_instance_s_seed_wins_over_the_caller_s(self):
        self.make(instance="SEED_IMAGE_NAME='pih/seed'\n")
        status, err, calls = self.initialize(SEED_IMAGE_NAME="other/seed")
        self.assertEqual(status, 0, err)
        self.assertEqual(calls, [("image", ["openmrs-db.sql.gz", "openmrs.tar.gz"],
                                  "pih/seed:latest")])

    def test_the_caller_s_seed_when_the_instance_has_none(self):
        self.make()
        status, err, calls = self.initialize(SEED_IMAGE_NAME="pih/seed", SEED_IMAGE_TAG="t")
        self.assertEqual(status, 0, err)
        self.assertEqual(calls[0][2], "pih/seed:t")

    def test_a_seed_s_entries_for_services_the_instance_lacks_are_left_out(self):
        self.make(services=("openmrs-db",), instance="SEED_IMAGE_NAME='pih/seed'\n")
        status, err, calls = self.initialize()
        self.assertEqual(status, 0, err)
        self.assertEqual(calls, [("image", ["openmrs-db.sql.gz"], "pih/seed:latest")])

    def test_a_seed_isn_t_used_when_restore_paths_cover_everything(self):
        self.make(instance="SEED_IMAGE_NAME='pih/seed'\n")
        status, err, calls = self.initialize(**self.dump(), **self.data())
        self.assertEqual(status, 0, err)
        self.assertEqual(calls[0][0], "folder")

    def test_a_database_source_is_needed(self):
        self.make()
        status, err, calls = self.initialize(**self.data())
        self.assertEqual(status, 1)
        self.assertIn("set exactly one of RESTORE_MYSQL_DUMP_PATH", err)
        self.assertEqual(calls, [])

    def test_a_restore_path_for_a_service_the_instance_lacks(self):
        self.make(services=("openmrs-db",))
        status, err, calls = self.initialize(**self.dump(), **self.data())
        self.assertEqual(status, 1)
        self.assertIn("kz has no openmrs service to restore RESTORE_OPENMRS_DATA_PATH into", err)

    def test_INITIALIZE_DB_TIMEOUT_is_pihx_s_timeout(self):
        self.make()
        status, err, _ = self.initialize(**self.dump(), INITIALIZE_DB_TIMEOUT="5")
        self.assertEqual(status, 0, err)
        self.assertEqual(os.environ.get("PIHX_INITIALIZE_TIMEOUT"), "5")

    def test_from_goes_to_pihx_but_not_with_restore_paths(self):
        self.make()
        with mock.patch.object(initialize, "cmd_initialize", return_value=0) as pihx:
            status, _, _ = self.front("kz", "initialize", "--from", "x")
        self.assertEqual(status, 0)
        pihx.assert_called_once_with("kz", ["--from", "x"])
        self.set_env(self.dump())
        status, _, err = self.front("kz", "initialize", "--from", "x")
        self.assertEqual(status, 2)
        self.assertIn("not both", err)
