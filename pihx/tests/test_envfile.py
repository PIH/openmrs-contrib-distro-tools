import contextlib
import io
import textwrap
import unittest

from pihx import envfile
from pihx.tests.fixtures import TempDirTest, write


class EnvFileTest(unittest.TestCase):
    def test_values_round_trip(self):
        for value in ["plain", "a $dollar and ${BRACES}", "with spaces", "has # hash", 'say "hi"',
                      "back\\slash", "`tick`", ""]:
            with self.subTest(value=value):
                line = envfile.format_line("NAME", value)
                self.assertEqual(envfile.parse(line + "\n"), {"NAME": value})

    def test_format_line_single_quotes(self):
        self.assertEqual(envfile.format_line("A", "x y"), "A='x y'")

    def test_format_line_refuses_what_compose_cant_read_back(self):
        for value in ["it's", "two\nlines", "cr\r", "ends\\"]:
            with self.subTest(value=value):
                with self.assertRaises(ValueError) as raised:
                    envfile.format_line("NAME", value)
                self.assertIn("NAME", str(raised.exception))
        with self.assertRaises(ValueError):
            envfile.format_line("1BAD", "x")

    def test_comments_and_blank_lines_are_ignored(self):
        text = ("# a comment\n\n   \nA=1\n  # indented comment\nB=2 # trailing\nC='3 # kept'\n"
                "D=x\t#tab isn't a comment\n")
        self.assertEqual(envfile.parse(text), {"A": "1", "B": "2", "C": "3 # kept",
                                               "D": "x\t#tab isn't a comment"})

    def test_quoting_as_compose_reads_it(self):
        text = ("A=unquoted value  \n"
                "B=no#comment\n"
                "C='single $x \\n'\n"
                'D="double \\"q\\" \\\\ \\n $x"\n'
                "export E=exported\n"
                "F=\n"
                "G = spaced\n"
                "H='it\\'s'\n"
                'I="\\$x \\y"\n'
                "J=a\\nb\n")
        self.assertEqual(envfile.parse(text), {
            "A": "unquoted value",
            "B": "no#comment",
            "C": "single $x \\n",
            "D": 'double "q" \\ \n $x',
            "E": "exported",
            "F": "",
            "G": "spaced",
            "H": "it's",
            "I": "\\$x \\y",
            "J": "a\\nb",
        })

    def test_later_lines_win(self):
        self.assertEqual(envfile.parse("A=1\nA=2\n"), {"A": "2"})

    def test_malformed_lines_are_errors_naming_the_line(self):
        for text in ["A=1\nNOEQUALS\n", "A=1\nK='abc\\'\n", "A=1\nB='unterminated\n", "A=1\n1X=2\n", "A=1\nB='x' junk\n"]:
            with self.subTest(text=text):
                with self.assertRaises(ValueError) as raised:
                    envfile.parse(text)
                self.assertIn("line 2", str(raised.exception))


class MergeTest(TempDirTest):
    def write(self, name, text):
        return write(self.root / name, text)

    def test_as_compose_config_shows_it(self):
        # Expected values from `docker compose --env-file a --env-file b config` in pihx-runtime,
        # with HOME=/tmp and SERVICE_NAME=kz in its environment (see the Task 2+3 report).
        a = self.write("a", textwrap.dedent("""\
            SERVICE_NAME=fromfile
            A=1
            B=$A-x
            C="${A}y \\$z"
            D='${A}'
            E=${UNSET:-dflt}
            F=${A:+set}
            G=$$A
            H=x #c
            I=x#c
            L=${NOPE}
            M="a\\nb"
            N=${HOME}
            R=${A}${B}
            S=a\\$b
            U=$Bz
            V=${B}z
            W=pre${SERVICE_NAME}
            EMPTY=
            X1=${EMPTY-d}
            X2=${EMPTY:-d}
            X4=${UNSET:-${A}z}
            X7='a\\'b'
            X8='a\\\\b'
            Y4="\\x\\$"
            D3="a\\\\$A"
            D7=${UNSET:-"q"}
            D9=$A$
            E1=${A}}
            E3=$1
            """))
        b = self.write("b", "A=2\nP=$A\nQ=$B\n")
        merged = envfile.merge([a, b], {"HOME": "/tmp", "SERVICE_NAME": "kz"})
        self.assertEqual(merged, {
            "SERVICE_NAME": "kz", "A": "2", "B": "1-x", "C": "1y $z", "D": "${A}", "E": "dflt",
            "F": "set", "G": "$A", "H": "x", "I": "x#c", "L": "", "M": "a\nb", "N": "/tmp",
            "R": "11-x", "S": "a\\", "U": "", "V": "1-xz", "W": "prekz", "EMPTY": "", "X1": "",
            "X2": "d", "X4": "1z", "X7": "a'b", "X8": "a\\\\b", "Y4": "\\x$", "D3": "a\\1",
            "D7": '"q"', "D9": "1$", "E1": "1}", "E3": "$1", "P": "2", "Q": "1-x",
        })

    def test_process_environment_wins_in_lookups(self):
        f1 = self.write("f1", "A=1\nP1=$A\nB=1\n")
        f2 = self.write("f2", "P2=$A\nB=2\nP3=$B\n")
        self.assertEqual(envfile.merge([f1, f2], {"A": "9"}),
                         {"A": "9", "P1": "9", "B": "2", "P2": "9", "P3": "2"})

    def test_required_variable(self):
        f = self.write("f", "A=1\nB=${UNSET:?needs it}\n")
        with self.assertRaises(ValueError) as raised:
            envfile.merge([f], {})
        self.assertIn(f"{f}: line 2: required variable UNSET is missing a value: needs it",
                      str(raised.exception))
        self.assertEqual(envfile.merge([self.write("g", "B=${A?x}\n")], {"A": "1"}), {"B": "1"})



class SetTest(TempDirTest):
    def test_set_replaces_every_line_defining_the_name_or_appends(self):
        f = write(self.root / "a.env", "# kept\nA=1\nB='x'\nA=2\n")
        f.chmod(0o600)
        envfile.set_value(f, "A", "a $b")
        self.assertEqual(f.read_text(), "# kept\nA='a $b'\nB='x'\n")
        envfile.set_value(f, "C", "false")
        self.assertEqual(f.read_text(), "# kept\nA='a $b'\nB='x'\nC='false'\n")
        self.assertEqual(f.stat().st_mode & 0o777, 0o600)

    def test_set_makes_a_missing_file_readable_by_its_owner_only(self):
        f = self.root / "new.env"
        envfile.set_value(f, "A", "1")
        self.assertEqual(f.read_text(), "A='1'\n")
        self.assertEqual(f.stat().st_mode & 0o777, 0o600)

    def test_set_refuses_a_file_it_cant_read_and_a_value_it_cant_write(self):
        f = write(self.root / "bad.env", "not a line\n")
        with self.assertRaises(ValueError):
            envfile.set_value(f, "A", "1")
        self.assertEqual(f.read_text(), "not a line\n")
        with self.assertRaises(ValueError):
            envfile.set_value(self.root / "a.env", "A", "it's")

    def test_set_from_the_command_line(self):
        f = self.root / "c.env"
        self.assertEqual(envfile.main(["set", str(f), "OPENMRS_DB_CREATED_EMPTY", "false"]), 0)
        self.assertEqual(f.read_text(), "OPENMRS_DB_CREATED_EMPTY='false'\n")
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(envfile.main(["set", str(f), "A"]), 2)


if __name__ == "__main__":
    unittest.main()
