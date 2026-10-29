import shutil
import unittest

from pihx import services
from pihx.tests.fixtures import TempDirTest, add_service, two_service_tools


class ServicesTest(TempDirTest):
    def setUp(self):
        super().setUp()
        self.tools = two_service_tools(self.root)

    def assert_service_error(self, name, *fragments):
        with self.assertRaises(services.ServiceError) as raised:
            services.load(self.tools, name)
        for fragment in fragments:
            self.assertIn(fragment, str(raised.exception))

    def test_services_load(self):
        found = services.all(self.tools)
        self.assertEqual(list(found), ["app", "db"])

        db = found["db"]
        self.assertEqual(db.name, "db")
        self.assertEqual(db.dir, self.tools / "services" / "db")
        self.assertEqual(db.compose_file, db.dir / "compose.yaml")
        self.assertEqual(db.defaults, {"DB_PASSWORD": "default", "DB_PORT": "3306", "SHARED": "db"})
        self.assertEqual(db.restore_dir, db.dir / "restore")
        self.assertIsNone(db.summary_script)
        self.assertEqual(db.commands, {})
        self.assertEqual(db.manifest, services.Manifest(
            description="A database",
            requires=[],
            setup=["db-accounts"],
            capture_env=["DB_OPT_"],
            job=False,
            backup="none",
            restore=[
                services.Restore(names=["db.sql", "db.sql.gz"], overlay="restore/dump.yaml"),
                services.Restore(names=["db.datadir/"], overlay="restore/datadir.yaml",
                                 after="restore/reset.yaml"),
            ],
        ))

        app = found["app"]
        self.assertEqual(app.manifest.description, "An app: on the database")
        self.assertEqual(app.manifest.requires, ["db"])
        self.assertIsNone(app.manifest.backup)
        self.assertEqual(app.manifest.restore, [])
        self.assertIsNone(app.restore_dir)
        self.assertEqual(app.summary_script, app.dir / "summary.sh")
        self.assertEqual(app.commands, {"bye": app.dir / "commands" / "bye",
                                        "hello": app.dir / "commands" / "hello"})

    def test_unknown_manifest_key_is_an_error(self):
        add_service(self.tools, "x", "description: x\nsetup-services: [a]\n")
        self.assert_service_error("x", str(self.tools / "services" / "x" / "service.yaml"),
                                  "setup-services")

    def test_requires_a_missing_service_is_an_error(self):
        add_service(self.tools, "x", "description: x\nrequires: [db, nosuch]\n")
        self.assert_service_error("x", "service.yaml", "nosuch")

    def test_restore_entry_needs_names_and_overlay(self):
        for entry, missing in [("  - overlay: restore/dump.yaml\n", "names"),
                               ("  - names: []\n    overlay: restore/dump.yaml\n", "names"),
                               ("  - names: [x.sql]\n", "overlay"),
                               ("  - names: [x.sql]\n    overlay: restore/nosuch.yaml\n", "nosuch"),
                               ("  - names: [x.sql]\n    overlay: restore/dump.yaml\n    var: X\n",
                                "var"),
                               ("  - names: [x.sql]\n    overlay: /etc/passwd\n", "/etc/passwd"),
                               ("  - names: [x.sql]\n    overlay: restore/dump.yaml\n"
                                "    after: ../db/restore/reset.yaml\n", "inside the service")]:
            with self.subTest(entry=entry):
                add_service(self.tools, "x", "description: x\nrestore:\n" + entry,
                            files=["restore/dump.yaml"])
                self.assert_service_error("x", "service.yaml", missing)

    def test_field_types_are_checked(self):
        for manifest, fragment in [("requires: [db]\n", "description"),
                                   ("description: x\nrequires: db\n", "requires"),
                                   ("description: x\njob: yes please\n", "job"),
                                   ("description: x\njob: yes\n", "job"),
                                   ("description: x\njob: True\n", "job"),
                                   ("description: x\nbackup: daily\n", "backup"),
                                   ("description: x\nsetup: [1, [2]]\n", "service.yaml"),
                                   ("- just\n- a list\n", "mapping")]:
            with self.subTest(manifest=manifest):
                add_service(self.tools, "x", manifest)
                self.assert_service_error("x", "service.yaml", fragment)

    def test_with_files_name_another_service(self):
        found = services.all(self.tools)
        self.assertEqual(found["app"].with_files, {"db": found["app"].dir / "with-db.yaml"})
        self.assertEqual(found["db"].with_files, {})

    def test_with_file_naming_an_unknown_service_is_an_error(self):
        (self.tools / "services" / "app" / "with-nothing.yaml").write_text("services: {}\n")
        self.assert_service_error("app", "with-nothing.yaml", "'nothing' isn't another service")

    def test_malformed_manifest_names_file_and_line(self):
        for manifest in ["description: x\n  stray: indent\n", "description: x\ndescription: y\n"]:
            with self.subTest(manifest=manifest):
                add_service(self.tools, "x", manifest)
                self.assert_service_error("x", "service.yaml", "line 2")

    def test_missing_files_are_errors(self):
        self.assert_service_error("nosuch", "nosuch")
        svc = add_service(self.tools, "x", "description: x\n")
        (svc / "compose.yaml").unlink()
        self.assert_service_error("x", "compose.yaml")

    def test_bad_env_defaults_names_the_file(self):
        add_service(self.tools, "x", "description: x\n", defaults="OK=1\nnot a line\n")
        self.assert_service_error("x", "env.defaults", "line 2")

    def test_service_names_cannot_be_core_commands(self):
        for name in ["start", "create", "initialize", "help", "list", "instance"]:
            with self.subTest(name=name):
                add_service(self.tools, name, "description: x\n")
                self.assert_service_error(name, name)
                with self.assertRaises(services.ServiceError):
                    services.all(self.tools)
                shutil.rmtree(self.tools / "services" / name)

    def test_restore_overlays_their_volumes_and_extension(self):
        db = self.tools / "services" / "db"
        (db / "restore" / "dump.yaml").write_text(
            "services:\n  db:\n    volumes:\n      - ${DB_RESTORE_PATH}:/init/x.sql:ro\n"
            "      - db-data:/var/lib/db\n  unpack:\n    volumes: [db-init:/t, '/abs:/abs']\n"
            "volumes:\n  db-init:\n")
        (db / "restore" / "reset.yaml").write_text(
            "services:\n  reset:\n    volumes:\n      - type: volume\n        source: db-data\n"
            "        target: /d\n")
        svc = services.load(self.tools, "db")
        self.assertEqual(svc.restore_overlays(), [db / "restore" / "dump.yaml",
                                                  db / "restore" / "datadir.yaml",
                                                  db / "restore" / "reset.yaml"])
        self.assertEqual(svc.restore_volumes(), {"db-init"})
        self.assertEqual(services.overlay_volumes(services.read_overlay(db / "restore" / "dump.yaml")),
                         ({"db-init"}, {"db-data", "db-init"}))
        self.assertEqual(services.overlay_volumes(services.read_overlay(db / "restore" / "reset.yaml")),
                         (set(), {"db-data"}))
        # An empty overlay is an empty mapping.
        self.assertEqual(services.read_overlay(db / "restore" / "datadir.yaml"), {})

    def test_a_bad_overlay_is_an_error(self):
        dump = self.tools / "services" / "db" / "restore" / "dump.yaml"
        for text, fragment in [("- a list\n", "mapping"),
                               ("services: [\n", "line")]:
            with self.subTest(text=text):
                dump.write_text(text)
                self.assert_service_error("db", "dump.yaml", fragment)

    def test_service_names_follow_the_name_rule(self):
        add_service(self.tools, "Bad_Name", "description: x\n")
        self.assert_service_error("Bad_Name", "Bad_Name")


if __name__ == "__main__":
    unittest.main()
