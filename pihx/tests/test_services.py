import shutil
import unittest

from pihx import services
from pihx.tests.fixtures import APP_MANIFEST, DB_MANIFEST, TempDirTest, add_service, two_service_tools


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
                                "var")]:
            with self.subTest(entry=entry):
                add_service(self.tools, "x", "description: x\nrestore:\n" + entry,
                            files=["restore/dump.yaml"])
                self.assert_service_error("x", "service.yaml", missing)

    def test_field_types_are_checked(self):
        for manifest, fragment in [("requires: [db]\n", "description"),
                                   ("description: x\nrequires: db\n", "requires"),
                                   ("description: x\njob: yes please\n", "job"),
                                   ("description: x\nbackup: daily\n", "backup"),
                                   ("description: x\nsetup: [1, [2]]\n", "service.yaml"),
                                   ("- just\n- a list\n", "mapping")]:
            with self.subTest(manifest=manifest):
                add_service(self.tools, "x", manifest)
                self.assert_service_error("x", "service.yaml", fragment)

    def test_malformed_manifest_names_file_and_line(self):
        add_service(self.tools, "x", "description: x\n  stray: indent\n")
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

    def test_service_names_follow_the_name_rule(self):
        add_service(self.tools, "Bad_Name", "description: x\n")
        self.assert_service_error("Bad_Name", "Bad_Name")


class YamlSubsetTest(unittest.TestCase):
    def test_fixture_manifests_parse(self):
        self.assertEqual(services.parse_yaml(APP_MANIFEST), {
            "description": "An app: on the database", "requires": ["db"], "job": False})
        self.assertEqual(services.parse_yaml(DB_MANIFEST)["restore"][1],
                         {"names": ["db.datadir/"], "overlay": "restore/datadir.yaml",
                          "after": "restore/reset.yaml"})

    def test_scalars(self):
        self.assertEqual(services.parse_yaml(
            "a: plain words # comment\nb: 'it''s # not a comment'\nc: \"x\"\nd: true\ne: []\n"
            "f:\ng: ~\nh: a#b\n"),
            {"a": "plain words", "b": "it's # not a comment", "c": "x", "d": True, "e": [],
             "f": None, "g": None, "h": "a#b"})

    def test_sequence_at_the_keys_indent(self):
        self.assertEqual(services.parse_yaml("a:\n- x\n- y\nb: z\n"), {"a": ["x", "y"], "b": "z"})

    def test_outside_the_subset_is_an_error(self):
        for text in ["a: {b: c}\n", "a: &anchor x\n", "a: |\n  text\n", "a: x\na: y\n",
                     "a:\n\tb: c\n", "a: [x, [y]]\n", "a: 'open\n", "a: \"es\\cape\"\n",
                     "a:\n  - x\n   - y\n"]:
            with self.subTest(text=text):
                with self.assertRaises(ValueError):
                    services.parse_yaml(text)


if __name__ == "__main__":
    unittest.main()
