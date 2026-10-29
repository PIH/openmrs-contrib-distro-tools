import subprocess
from pathlib import Path
from unittest import mock

from pihx import compose, instance
from pihx.commands import CliError, initialize
from pihx.tests.fixtures import add_service, two_service_instance, write
from pihx.tests.test_instance_cmds import CommandTest, run


def done(stdout="", returncode=0):
    return subprocess.CompletedProcess([], returncode, stdout=stdout, stderr="")


class InitializeTest(CommandTest):
    """The fixture checkout: db accepts db.sql, db.sql.gz (restore/dump.yaml) and db.datadir/
    (restore/datadir.yaml, then restore/reset.yaml); app accepts nothing."""

    def setUp(self):
        super().setUp()
        self.home, self.tools = two_service_instance(self.root)
        self.set_env({})
        self.inst = instance.open(self.home, "kz", tools=self.tools)

    def choose(self, *entries):
        return initialize.choose(self.inst, Path("/f"), list(entries))

    def assert_choice_error(self, entries, *fragments):
        with self.assertRaises(CliError) as raised:
            self.choose(*entries)
        for fragment in fragments:
            self.assertIn(fragment, str(raised.exception))


class ChooseTest(InitializeTest):
    def test_archive_names(self):
        for name, archive in [("db.7z", "archive.7z"), ("db.sql.7z", "archive.7z"),
                              ("x.zip", "archive.zip"), ("x.tar.gz", "archive.tar.gz"),
                              ("x.tgz", "archive.tar.gz"), ("x.tar", "archive.tar"),
                              ("x.sql", None), ("x.sql.gz", None), ("x", None)]:
            with self.subTest(name=name):
                self.assertEqual(initialize.archive_name_for(name), archive)

    def test_an_entry_is_matched_to_its_service(self):
        [choice] = self.choose(("db.sql.gz", "file"))
        self.assertEqual(choice.service.name, "db")
        self.assertEqual(choice.restore.overlay, "restore/dump.yaml")
        self.assertEqual(choice.path, Path("/f/db.sql.gz"))

    def test_a_directory_entry_is_named_without_its_slash(self):
        [choice] = self.choose(("db.datadir", "dir"))
        self.assertEqual(choice.restore.after, "restore/reset.yaml")
        # A link the host resolves can't be told apart here: its name decides.
        [choice] = self.choose(("db.datadir", None))
        self.assertEqual(choice.entry, "db.datadir")

    def test_an_entry_of_the_wrong_kind_is_an_error(self):
        self.assert_choice_error([("db.datadir", "file")], "db.datadir", "a directory")
        self.assert_choice_error([("db.sql", "dir")], "db.sql", "a file")

    def test_two_entries_for_one_service_is_an_error(self):
        self.assert_choice_error([("db.sql", "file"), ("db.datadir", "dir")],
                                 "db.datadir", "db.sql", "db")

    def test_an_entry_for_no_service_is_an_error(self):
        self.assert_choice_error([("db.sql", "file"), ("notes.txt", "file")], "notes.txt",
                                 "no service")

    def test_an_entry_for_a_service_the_instance_lacks_is_an_error(self):
        add_service(self.tools, "cache", "description: c\nrestore:\n"
                    "  - names: [cache.tar]\n    overlay: restore/x.yaml\n",
                    files=["restore/x.yaml"])
        self.assert_choice_error([("cache.tar", "file")], "cache.tar", "cache", "isn't part of kz")

    def test_a_service_without_an_entry_starts_empty(self):
        self.assertEqual(self.choose(), [])

    def test_restore_variables(self):
        choices = self.choose(("db.sql", "file"))
        self.assertEqual(initialize.restore_variables(choices),
                         {"DB_RESTORE_PATH": "/f/db.sql", "DB_RESTORE_NAME": "db.sql"})
        (self.tools / "services" / "db" / "service.yaml").write_text(
            "description: d\nrestore:\n  - names: [db.percona.7z]\n"
            "    overlay: restore/dump.yaml\n")
        (self.home / "kz" / "app.env").unlink()
        add_service(self.tools, "my-app", "description: a\nrestore:\n"
                    "  - names: [my-app/]\n    overlay: restore/x.yaml\n",
                    files=["restore/x.yaml"])
        write(self.home / "kz" / "my-app.env", "")
        self.inst = instance.open(self.home, "kz", tools=self.tools)
        choices = self.choose(("db.percona.7z", "file"), ("my-app", "dir"))
        self.assertEqual(initialize.restore_variables(choices), {
            "DB_RESTORE_PATH": "/f/db.percona.7z", "DB_RESTORE_NAME": "db.percona.7z",
            "DB_RESTORE_ARCHIVE": "archive.7z",
            "MY_APP_RESTORE_PATH": "/f/my-app", "MY_APP_RESTORE_NAME": "my-app"})

    def test_referenced_variables(self):
        overlay = write(self.root / "o.yaml",
                        "services:\n  x:\n    image: ${P7ZIP_IMAGE:?must be set}\n"
                        "    environment:\n      - ARCHIVE_PASSWORD\n      - NAME=${DB_RESTORE_NAME}\n"
                        "    command: [sh, -c, 'echo $$NOT_THIS ${OWNER-x}']\n"
                        "  y:\n    environment: {MAPPED: null, SET: '1'}\n")
        self.assertEqual(initialize.referenced_variables(overlay),
                         {"P7ZIP_IMAGE", "ARCHIVE_PASSWORD", "DB_RESTORE_NAME", "OWNER", "MAPPED"})


class FromFolderTest(InitializeTest):
    def test_the_launchers_resolved_folder_is_used(self):
        folder = self.root / "elsewhere"
        folder.mkdir()
        self.set_env({"PIHX_FROM": str(folder)})
        self.assertEqual(initialize.from_folder("./typed"), folder)

    def test_a_relative_folder_resolves_against_the_callers_directory(self):
        folder = self.home / "runs" / "one"
        folder.mkdir(parents=True)
        self.set_env({"PIHX_CWD": str(self.home / "runs")})
        self.assertEqual(initialize.from_folder("./one"), folder)

    def test_a_folder_outside_the_mounted_paths_is_an_error(self):
        with self.assertRaises(CliError) as raised:
            initialize.from_folder("/")
        self.assertIn("bin/pihx", str(raised.exception))

    def test_a_missing_folder_is_an_error(self):
        with self.assertRaises(CliError) as raised:
            initialize.from_folder(str(self.home / "nosuch"))
        self.assertIn("isn't a directory", str(raised.exception))


class InitializeCommandTest(InitializeTest):
    def setUp(self):
        super().setUp()
        self.docker_calls = []
        self.existing_volumes = set()
        write(self.tools / "utils" / "lib" / "images.sh", "ALPINE_IMAGE=alpine:3.21\n")

    def fake_docker(self, argv, **kwargs):
        self.docker_calls.append(argv[1:])
        if argv[1:3] == ["volume", "inspect"]:
            return done(returncode=0 if argv[3] in self.existing_volumes else 1)
        return done()

    def run_pihx(self, *argv):
        def fake_run(compose_self, *args, **kwargs):
            self.compose_calls.append(args)
            return done()
        with mock.patch.object(compose.Compose, "run", fake_run), \
                mock.patch.object(initialize.subprocess, "run", self.fake_docker):
            return run(list(argv))

    def test_a_source_is_required_and_only_one(self):
        for argv in ([], ["--from", "a", "--from-image", "b"], ["--from"], ["--other"]):
            with self.subTest(argv=argv):
                status, _, err = self.run_pihx("kz", "initialize", *argv)
                self.assertEqual(status, 2, err)
                self.assertEqual(self.compose_calls, [])

    def test_an_existing_volume_a_restore_writes_is_refused(self):
        (self.tools / "services" / "db" / "restore" / "dump.yaml").write_text(
            "services:\n  db:\n    volumes: [db-data:/d]\n")
        folder = write(self.home / "run" / "db.sql", "").parent
        self.existing_volumes = {"kz_db-data"}
        status, _, err = self.run_pihx("kz", "initialize", "--from", str(folder))
        self.assertEqual(status, 1)
        self.assertIn("kz_db-data already exists", err)
        self.assertIn("pihx kz destroy", err)
        self.assertEqual(self.compose_calls, [])

    def test_an_empty_folder_is_an_error(self):
        (self.home / "run").mkdir()
        status, _, err = self.run_pihx("kz", "initialize", "--from", str(self.home / "run"))
        self.assertEqual(status, 1)
        self.assertIn("nothing to restore", err)
