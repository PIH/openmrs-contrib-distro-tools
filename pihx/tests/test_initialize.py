import json
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


class FromDirectoryTest(InitializeTest):
    def test_the_launchers_resolved_directory_is_used(self):
        folder = self.root / "elsewhere"
        folder.mkdir()
        self.set_env({"PIHX_FROM": str(folder)})
        self.assertEqual(initialize.from_folder("./typed"), folder)

    def test_a_relative_directory_resolves_against_the_callers_directory(self):
        folder = self.home / "runs" / "one"
        folder.mkdir(parents=True)
        self.set_env({"PIHX_CWD": str(self.home / "runs")})
        self.assertEqual(initialize.from_folder("./one"), folder)

    def test_a_directory_outside_the_mounted_paths_is_an_error(self):
        with self.assertRaises(CliError) as raised:
            initialize.from_folder("/")
        self.assertIn("bin/pihx", str(raised.exception))

    def test_a_missing_directory_is_an_error(self):
        with self.assertRaises(CliError) as raised:
            initialize.from_folder(str(self.home / "nosuch"))
        self.assertIn("isn't a directory", str(raised.exception))


class InitializeCommandTest(InitializeTest):
    def setUp(self):
        super().setUp()
        self.docker_calls = []
        self.existing_volumes = set()
        self.failing_listings = 0
        self.hooks, self.hook_envs, self.compose_envs = {}, {}, []
        # db's own container mounts db-data; a shared, external volume isn't the instance's.
        self.config = {"services": {"db": {"volumes": [
            {"type": "volume", "source": "db-data", "target": "/d"},
            {"type": "volume", "source": "backups", "target": "/b"},
            {"type": "bind", "source": "/x", "target": "/x"}]}},
            "volumes": {"db-data": {"name": "kz_db-data"},
                        "backups": {"name": "backups", "external": True}}}
        self.folder = write(self.home / "run" / "db.sql", "").parent
        write(self.tools / "utils" / "lib" / "images.sh", "ALPINE_IMAGE=alpine:3.21\n")

    def fake_docker(self, argv, **kwargs):
        self.docker_calls.append(argv[1:] if argv[0] == "docker" else argv)
        if argv[0] != "docker":
            hook = Path(argv[0]).name
            self.hook_envs[hook] = kwargs.get("env", {})
            return self.hooks.get(hook, lambda: done())()
        if argv[1:3] == ["volume", "inspect"]:
            return done(returncode=0 if argv[3] in self.existing_volumes else 1)
        if argv[1:3] == ["volume", "ls"]:
            if self.failing_listings:
                self.failing_listings -= 1
                return done(returncode=1)
            names = self.existing_volumes
            if "label=com.docker.compose.project=kz" in argv:
                names = {n for n in names if n.startswith("kz_")}
            return done("".join(f"{n}\n" for n in sorted(names)))
        return done()

    def run_pihx(self, *argv):
        def fake_run(compose_self, *args, **kwargs):
            self.compose_calls.append(args)
            self.compose_envs.append(compose_self.environment())
            if "config" in args:
                return done(json.dumps(self.config))
            return done()
        with mock.patch.object(compose.Compose, "run", fake_run), \
                mock.patch.object(initialize.subprocess, "run", self.fake_docker):
            return run(list(argv))

    def up_calls(self):
        return [c for c in self.compose_calls if "up" in c]

    def test_a_source_is_required_and_only_one(self):
        for argv in ([], ["--from", "a", "--from-image", "b"], ["--from"], ["--other"]):
            with self.subTest(argv=argv):
                status, _, err = self.run_pihx("kz", "initialize", *argv)
                self.assertEqual(status, 2, err)
                self.assertEqual(self.compose_calls, [])

    def test_an_existing_volume_of_a_restoring_service_is_refused(self):
        # Not one the overlay names: the dump overlay only adds a file to the db container.
        for existing in ("kz_db-data", "kz_db-init"):
            with self.subTest(existing=existing):
                (self.tools / "services" / "db" / "restore" / "dump.yaml").write_text(
                    "services:\n  db: {}\n  unpack:\n    volumes: [db-init:/t]\n"
                    "volumes:\n  db-init:\n")
                self.existing_volumes = {existing, "backups"}
                status, _, err = self.run_pihx("kz", "initialize", "--from", str(self.folder))
                self.assertEqual(status, 1)
                self.assertIn(f"{existing} already exists", err)
                self.assertIn("pihx kz destroy", err)
                self.assertEqual(self.up_calls(), [])

    def test_an_external_volume_is_not_refused(self):
        self.existing_volumes = {"backups"}
        status, _, err = self.run_pihx("kz", "initialize", "--from", str(self.folder))
        self.assertEqual(status, 0, err)
        self.assertEqual(len(self.up_calls()), 1)

    def test_prepare_gives_values_for_this_run_and_a_failing_hook_names_its_service(self):
        write(self.tools / "services" / "db" / "restore" / "prepare", "")
        self.hooks["prepare"] = lambda: done("DB_OWNER=1:2\n\n")
        status, _, err = self.run_pihx("kz", "initialize", "--from", str(self.folder))
        self.assertEqual(status, 0, err)
        self.assertEqual(self.compose_envs[-1]["DB_OWNER"], "1:2")
        # The hook gets the script environment and the instance's values.
        self.assertEqual(self.hook_envs["prepare"]["PIHX_INSTANCE"], "kz")
        self.assertEqual(self.hook_envs["prepare"]["DB_PASSWORD"], "secret $x")
        for result, fragment in [(done(returncode=3), "db: restore/prepare failed (exit 3)"),
                                 (done("not a value\n"), "printed a malformed line"),
                                 (done("BAD NAME=s3cret\n"), "printed a malformed line")]:
            with self.subTest(fragment=fragment):
                self.compose_calls.clear()
                self.hooks["prepare"] = lambda: result
                status, _, err = self.run_pihx("kz", "initialize", "--from", str(self.folder))
                self.assertEqual(status, 1)
                self.assertIn(fragment, err)
                self.assertNotIn("not a value", err)
                self.assertNotIn("BAD NAME", err)
                self.assertNotIn("s3cret", err)
                self.assertEqual(self.up_calls(), [])

    def test_a_failing_finish_is_cleaned_up_like_a_failed_restore(self):
        write(self.tools / "services" / "db" / "restore" / "finish", "")
        db_env = self.home / "kz" / "db.env"
        before = db_env.read_text()

        def finish():
            db_env.write_text(before + "WRITTEN=1\n")
            write(self.home / "kz" / "new.env", "")
            self.existing_volumes = {"kz_db-data"}
            return done(returncode=1)
        self.hooks["finish"] = finish
        status, _, err = self.run_pihx("kz", "initialize", "--from", str(self.folder))
        self.assertEqual(status, 1)
        self.assertIn("db: restore/finish failed (exit 1)", err)
        self.assertEqual(db_env.read_text(), before)
        self.assertFalse((self.home / "kz" / "new.env").exists())
        self.assertIn(("down",), self.compose_calls)

    def test_a_volume_left_after_a_failure_is_named_with_destroy(self):
        write(self.tools / "services" / "db" / "restore" / "finish", "")

        def finish():
            self.existing_volumes = {"kz_db-init"}
            return done(returncode=1)
        self.hooks["finish"] = finish
        (self.tools / "services" / "db" / "restore" / "dump.yaml").write_text(
            "services:\n  unpack:\n    volumes: [db-init:/t]\nvolumes:\n  db-init:\n")
        status, _, err = self.run_pihx("kz", "initialize", "--from", str(self.folder))
        self.assertEqual(status, 1)
        self.assertIn("Couldn't remove kz_db-init (db-init holds a full copy", err)
        self.assertIn("'pihx kz destroy'", err)

    def removed_volumes(self):
        return [c[2:] for c in self.docker_calls if c[:2] == ["volume", "rm"]]

    def test_a_failure_removes_only_volumes_shown_to_be_new(self):
        write(self.tools / "services" / "db" / "restore" / "finish", "")
        self.existing_volumes = {"kz_petl-data"}

        def finish():
            self.existing_volumes = {"kz_petl-data", "kz_db-data"}
            return done(returncode=1)
        self.hooks["finish"] = finish
        status, _, err = self.run_pihx("kz", "initialize", "--from", str(self.folder))
        self.assertEqual(status, 1, err)
        self.assertEqual(self.removed_volumes(), [["kz_db-data"]])

    def test_a_failed_listing_before_the_restore_removes_nothing(self):
        self.existing_volumes = {"kz_petl-data", "kz_sqlserver-data"}
        # The first listing (the existence check) works; the snapshot's fails.
        self.failing_listings = 1
        real = initialize.Restore.refuse_existing_volumes

        def refuse(restore):
            self.failing_listings = 0
            real(restore)
            self.failing_listings = 1
        with mock.patch.object(initialize.Restore, "refuse_existing_volumes", refuse):
            status, _, err = self.run_pihx("kz", "initialize", "--from", str(self.folder))
        self.assertEqual(status, 1)
        self.assertIn("couldn't list Docker's volumes", err)
        self.assertEqual(self.removed_volumes(), [])
        self.assertEqual(self.up_calls(), [])

    def test_a_failed_listing_after_a_failure_removes_only_the_staging_volumes(self):
        write(self.tools / "services" / "db" / "restore" / "finish", "")
        (self.tools / "services" / "db" / "restore" / "dump.yaml").write_text(
            "services:\n  unpack:\n    volumes: [db-init:/t]\nvolumes:\n  db-init:\n")
        self.existing_volumes = {"kz_petl-data"}

        def finish():
            self.existing_volumes = {"kz_petl-data", "kz_db-init"}
            self.failing_listings = 1
            return done(returncode=1)
        self.hooks["finish"] = finish
        status, _, err = self.run_pihx("kz", "initialize", "--from", str(self.folder))
        self.assertEqual(status, 1)
        self.assertIn("removing only the restore's staging volumes", err)
        self.assertEqual(self.removed_volumes(), [["kz_db-init"]])

    def test_a_failed_listing_refuses_before_anything_is_made(self):
        self.failing_listings = 1
        status, _, err = self.run_pihx("kz", "initialize", "--from", str(self.folder))
        self.assertEqual(status, 1)
        self.assertIn("couldn't list Docker's volumes", err)
        self.assertEqual(self.removed_volumes(), [])
        self.assertEqual(self.up_calls(), [])

    def test_an_empty_directory_is_an_error(self):
        (self.home / "empty").mkdir()
        status, _, err = self.run_pihx("kz", "initialize", "--from", str(self.home / "empty"))
        self.assertEqual(status, 1)
        self.assertIn("nothing to restore", err)
