import unittest

from pihx import envfile


class EnvFileTest(unittest.TestCase):
    def test_values_round_trip(self):
        for value in ["plain", "a $dollar and ${BRACES}", "with spaces", "has # hash", 'say "hi"',
                      "back\\slash", "`tick`", ""]:
            with self.subTest(value=value):
                line = envfile.format_line("NAME", value)
                self.assertEqual(envfile.parse(line + "\n"), {"NAME": value})

    def test_format_line_single_quotes(self):
        self.assertEqual(envfile.format_line("A", "x y"), "A='x y'")

    def test_format_line_refuses_single_quote_and_newline(self):
        for value in ["it's", "two\nlines", "cr\r"]:
            with self.subTest(value=value):
                with self.assertRaises(ValueError) as raised:
                    envfile.format_line("NAME", value)
                self.assertIn("NAME", str(raised.exception))
        with self.assertRaises(ValueError):
            envfile.format_line("1BAD", "x")

    def test_comments_and_blank_lines_are_ignored(self):
        text = "# a comment\n\n   \nA=1\n  # indented comment\nB=2 # trailing\nC='3 # kept'\n"
        self.assertEqual(envfile.parse(text), {"A": "1", "B": "2", "C": "3 # kept"})

    def test_quoting_as_compose_reads_it(self):
        text = ("A=unquoted value  \n"
                "B=no#comment\n"
                "C='single $x \\n'\n"
                'D="double \\"q\\" \\\\ \\n $x"\n'
                "export E=exported\n"
                "F=\n"
                "G = spaced\n")
        self.assertEqual(envfile.parse(text), {
            "A": "unquoted value",
            "B": "no#comment",
            "C": "single $x \\n",
            "D": 'double "q" \\ \n $x',
            "E": "exported",
            "F": "",
            "G": "spaced",
        })

    def test_later_lines_win(self):
        self.assertEqual(envfile.parse("A=1\nA=2\n"), {"A": "2"})

    def test_malformed_lines_are_errors_naming_the_line(self):
        for text in ["A=1\nNOEQUALS\n", "A=1\nB='unterminated\n", "A=1\n1X=2\n", "A=1\nB='x' junk\n"]:
            with self.subTest(text=text):
                with self.assertRaises(ValueError) as raised:
                    envfile.parse(text)
                self.assertIn("line 2", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
