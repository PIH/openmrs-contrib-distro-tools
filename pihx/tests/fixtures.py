"""Fixture checkouts and instance directories for the unit tests."""

import tempfile
import unittest
from pathlib import Path

DB_MANIFEST = """\
# The database.
description: A database
capture-env: [DB_OPT_]
setup:
  - db-accounts
backup: none
restore:
  - names: [db.sql, "db.sql.gz"]
    overlay: restore/dump.yaml
  - names:
      - db.datadir/
    overlay: restore/datadir.yaml
    after: restore/reset.yaml
"""

APP_MANIFEST = """\
description: 'An app: on the database'
requires: [db]
job: false
"""


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    return path


def add_service(tools, name, manifest, defaults="", files=()):
    svc = tools / "services" / name
    write(svc / "service.yaml", manifest)
    write(svc / "compose.yaml", f"services:\n  {name}:\n    image: alpine\n")
    write(svc / "env.defaults", defaults)
    for f in files:
        write(svc / f, "")
    return svc


def two_service_tools(root):
    """A checkout with services db and app."""
    tools = Path(root) / "tools"
    write(tools / "instance.env.defaults", "TZ=UTC\nSHARED=tools\n")
    add_service(tools, "db", DB_MANIFEST, "DB_PASSWORD=default\nDB_PORT=3306\nSHARED=db\n",
                ["restore/dump.yaml", "restore/datadir.yaml", "restore/reset.yaml"])
    add_service(tools, "app", APP_MANIFEST, "APP_PORT=8080\nSHARED=app\n",
                ["summary.sh", "commands/hello", "commands/bye"])
    return tools


class TempDirTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)


def two_service_instance(root, name="kz"):
    """An instance <name> under <root>/home of two_service_tools, with an app override.
    Returns (home, tools)."""
    tools = two_service_tools(root)
    home = Path(root) / "home"
    write(home / name / "db.env", "DB_PASSWORD='secret $x'\n")
    write(home / name / "app.env", "APP_PORT=9090\n")
    write(home / name / "instance.env", "TZ=Africa/Kigali\nSHARED=instance\n")
    write(home / name / "app.override.yaml", "services: {}\n")
    write(home / name / "notes.txt", "not an env file\n")
    return home, tools
