"""The Python code imports only the standard library, PyYAML and its own packages: the dependency
policy in docs/development.md#dependencies. pihx runs only in pihx-runtime, which provides those and
nothing else, so an import outside this list would fail on every machine that hasn't installed it by
hand. Adding a package is a team decision; when agreed, it goes in images/pihx-runtime/Dockerfile
(an Alpine py3-* package, or pip there pinned to an exact version) and in ALLOWED below."""

import ast
import sys
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[2]
# The packages of this repo, and the third-party ones the image provides (py3-yaml).
OWN = {"pihx", "openmrs"}
ALLOWED = {"yaml"}


def top_level_imports(path):
    """The top-level module names <path> imports, with the line of each (relative imports skipped)."""
    tree = ast.parse(path.read_text(), filename=str(path))
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                yield alias.name.split(".")[0], node.lineno
        elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
            yield node.module.split(".")[0], node.lineno


class ImportsTest(unittest.TestCase):
    def test_only_the_standard_library_yaml_and_own_packages(self):
        files = sorted(p for d in ("pihx", "openmrs", "services") for p in (TOOLS / d).rglob("*.py"))
        self.assertTrue(files)
        outside = [f"{path.relative_to(TOOLS)}:{line}: import {name}"
                   for path in files for name, line in top_level_imports(path)
                   if name not in sys.stdlib_module_names and name not in OWN | ALLOWED]
        self.assertEqual(outside, [], "imports outside the dependency policy "
                         "(docs/development.md#dependencies):\n" + "\n".join(outside))


if __name__ == "__main__":
    unittest.main()
