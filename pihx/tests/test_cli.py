import contextlib
import io
import os
import unittest
from unittest import mock

from pihx import cli


def run(argv):
    """Runs cli.main, returning (status, stdout, stderr)."""
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        status = cli.main(argv)
    return status, out.getvalue(), err.getvalue()


def run_raising(error, environ=None):
    """cli.main with a dispatch that raises <error>: (status, stderr)."""
    err = io.StringIO()
    with mock.patch.dict(os.environ, environ or {}), contextlib.redirect_stderr(err), \
            mock.patch.object(cli, "dispatch", side_effect=error):
        os.environ.pop("PIHX_DOCKER_CONFIG", None)
        status = cli.main([])
    return status, err.getvalue()


class CliTest(unittest.TestCase):
    def test_ctrl_c_is_one_line_and_exit_130(self):
        self.assertEqual(run_raising(KeyboardInterrupt()), (130, "error: interrupted\n"))

    def test_an_unexpected_error_is_one_line_with_its_traceback_only_under_pihx_debug(self):
        with mock.patch.dict(os.environ):
            os.environ.pop("PIHX_DEBUG", None)
            status, err = run_raising(KeyError("x"))
        self.assertEqual(status, 1)
        self.assertEqual(err, "error: 'x' (PIHX_DEBUG=1 shows where)\n")
        status, err = run_raising(ZeroDivisionError(), {"PIHX_DEBUG": "1"})
        self.assertEqual(status, 1)
        self.assertIn("Traceback", err)
        self.assertTrue(err.endswith("error: ZeroDivisionError (PIHX_DEBUG=1 shows where)\n"))

    def test_global_commands(self):
        status, out, _ = run(["version"])
        self.assertEqual(status, 0)
        self.assertRegex(out, r"^pihx \d+\.\d+")

        status, out, _ = run(["help"])
        self.assertEqual(status, 0)
        self.assertIn("pihx <instance> <command>", out)

        status, _, err = run([])
        self.assertNotEqual(status, 0)
        self.assertIn("error:", err)

    def test_instance_name_rules(self):
        for name in ["list", "help", "version", "Bad_Name", "-x", "_x", "a/b", ""]:
            with self.subTest(name=name):
                self.assertIsNotNone(cli.instance_name_error(name))
        for name in ["kz", "endtb-1", "a_b", "0x"]:
            with self.subTest(name=name):
                self.assertIsNone(cli.instance_name_error(name))

        status, _, err = run(["Bad_Name", "version"])
        self.assertNotEqual(status, 0)
        self.assertIn("error:", err)
        self.assertIn("Bad_Name", err)

    def test_unknown_command_is_an_error(self):
        status, _, err = run(["kz", "nosuch"])
        self.assertNotEqual(status, 0)
        self.assertTrue(err.rstrip().splitlines()[-1].startswith("error:"))


if __name__ == "__main__":
    unittest.main()
