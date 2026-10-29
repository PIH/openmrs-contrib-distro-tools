"""Env files: KEY=value lines, read as Docker Compose reads them, written single-quoted."""

import re

NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
LINE = re.compile(r"\s*(?:export\s+)?([^=\s]*)\s*=\s*(.*)")
DOUBLE_QUOTED_ESCAPES = {"n": "\n", "r": "\r", "t": "\t", '"': '"', "\\": "\\"}


def parse(text):
    """The variables in an env file's text. Values are returned as written: `${VAR}` is left for
    Compose to interpolate. Raises ValueError naming the line for a line Compose wouldn't read the
    same way."""
    values = {}
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = LINE.fullmatch(line)
        if not match or not NAME.fullmatch(match.group(1)):
            raise ValueError(f"line {number}: expected NAME=value")
        try:
            values[match.group(1)] = _value(match.group(2))
        except ValueError as e:
            raise ValueError(f"line {number}: {e}") from None
    return values


def _value(raw):
    if raw[:1] == "'":
        end = raw.find("'", 1)
        if end < 0:
            raise ValueError("unterminated single quote")
        value, rest = raw[1:end], raw[end + 1:]
    elif raw[:1] == '"':
        chars, i = [], 1
        while i < len(raw) and raw[i] != '"':
            if raw[i] == "\\" and i + 1 < len(raw) and raw[i + 1] in DOUBLE_QUOTED_ESCAPES:
                chars.append(DOUBLE_QUOTED_ESCAPES[raw[i + 1]])
                i += 2
            else:
                chars.append(raw[i])
                i += 1
        if i == len(raw):
            raise ValueError("unterminated double quote")
        value, rest = "".join(chars), raw[i + 1:]
    else:
        # An unquoted value's comment starts at a '#' after whitespace.
        return re.split(r"\s#", raw, maxsplit=1)[0].strip()
    if rest.strip() and not rest.strip().startswith("#"):
        raise ValueError("text after the closing quote")
    return value


def format_line(name, value):
    """NAME='value'. Single-quoted values are literal to Compose (and to sh), so `$`, `"`, `#`,
    backticks and backslashes are safe; a single quote or newline can't be, so it's refused."""
    if not NAME.fullmatch(name):
        raise ValueError(f"'{name}' isn't a valid variable name")
    if any(c in value for c in "'\n\r"):
        raise ValueError(f"{name} contains a single quote or newline, which an env file can't hold")
    return f"{name}='{value}'"
