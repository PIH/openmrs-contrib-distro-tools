"""Env files: KEY=value lines, read as Docker Compose (compose-go's dotenv) reads them, written
single-quoted.

Compose's rules, checked against `docker compose config` in pihx-runtime:
- unquoted: trimmed; a comment starts at " #" (a space, not a tab); backslashes are literal;
  `$` references are expanded
- single-quoted: literal, except that \\' is a quote (so it doesn't close the value)
- double-quoted: \\n \\r \\t \\" \\\\ and \\$ (a literal $) are escapes, other backslashes literal;
  `$` references are expanded
- expansion: $NAME, ${NAME}, ${NAME:-default}, ${NAME-default}, ${NAME:+alt}, ${NAME+alt},
  ${NAME:?message}, ${NAME?message}, $$ for a literal $; an unset name expands to ''. Names are
  looked up in the process environment first (it wins outright), then in values read before.
"""

import re

NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
LINE = re.compile(r"\s*(?:export\s+)?([^=\s]*)\s*=\s*(.*)")
DOUBLE_QUOTED_ESCAPES = {"n": "\n", "r": "\r", "t": "\t", '"': '"', "\\": "\\"}
# Stands for \$ in a double-quoted value until expansion is done.
ESCAPED_DOLLAR = "\0"
BRACED = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)(?:(:?[-+?])(.*))?", re.DOTALL)


def parse(text):
    """The variables in an env file's text, unexpanded: `$` references (and a double-quoted \\$)
    are left as written. Raises ValueError naming the line for a line Compose can't read."""
    return {name: body.replace(ESCAPED_DOLLAR, "\\$") for _, name, _, body in _entries(text)}


def merge(paths, environ):
    """The values Compose's interpolation sees after reading the env files <paths> in order (later
    files win), with `$` references expanded, given the process environment <environ>: a name it
    sets takes its value from it, as Compose does. Raises ValueError naming the file and line."""
    values = {}

    def lookup(name):
        return environ[name] if name in environ else values.get(name)

    for path in paths:
        try:
            with open(path) as f:
                text = f.read()
            for number, name, quote, body in _entries(text):
                try:
                    if quote != "'":
                        body = expand(body, lookup).replace(ESCAPED_DOLLAR, "$")
                except ValueError as e:
                    raise ValueError(f"line {number}: {e}") from None
                values[name] = body
        except (OSError, ValueError) as e:
            raise ValueError(f"{path}: {e}") from None
    return {name: environ.get(name, value) for name, value in values.items()}


def _entries(text):
    """(line number, name, quote, body) for each variable; quote is ', " or ''."""
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = LINE.fullmatch(line)
        if not match or not NAME.fullmatch(match.group(1)):
            raise ValueError(f"line {number}: expected NAME=value")
        try:
            quote, body = _value(match.group(2))
        except ValueError as e:
            raise ValueError(f"line {number}: {e}") from None
        yield number, match.group(1), quote, body


def _value(raw):
    quote = raw[:1]
    if quote not in ("'", '"'):
        return "", raw.split(" #", 1)[0].strip()
    chars, i = [], 1
    while i < len(raw) and raw[i] != quote:
        following = raw[i + 1:i + 2]
        if raw[i] == "\\" and quote == "'" and following == "'":
            chars.append("'")
            i += 2
        elif raw[i] == "\\" and quote == '"' and following in DOUBLE_QUOTED_ESCAPES:
            chars.append(DOUBLE_QUOTED_ESCAPES[following])
            i += 2
        elif raw[i] == "\\" and quote == '"' and following == "$":
            chars.append(ESCAPED_DOLLAR)
            i += 2
        else:
            chars.append(raw[i])
            i += 1
    if i == len(raw):
        raise ValueError("unterminated quoted value")
    rest = raw[i + 1:].strip()
    if rest and not rest.startswith("#"):
        raise ValueError("text after the closing quote")
    return quote, "".join(chars)


def expand(text, lookup):
    """<text> with `$` references expanded; <lookup>(name) returns a value, or None if unset."""
    out, i = [], 0
    while i < len(text):
        c = text[i]
        following = text[i + 1:i + 2]
        if c != "$":
            out.append(c)
            i += 1
        elif following == "$":
            out.append("$")
            i += 2
        elif following == "{":
            end, depth = i + 2, 1
            while end < len(text) and depth:
                if text.startswith("${", end):
                    depth += 1
                    end += 1
                elif text[end] == "}":
                    depth -= 1
                end += 1
            if depth:
                raise ValueError(f"unterminated ${{ in {text}")
            out.append(_braced(text[i + 2:end - 1], lookup))
            i = end
        else:
            match = NAME.match(text, i + 1)
            if match:
                out.append(lookup(match.group()) or "")
                i = match.end()
            else:
                out.append("$")
                i += 1
    return "".join(out)


def _braced(inner, lookup):
    match = BRACED.fullmatch(inner)
    if not match:
        raise ValueError(f"bad substitution ${{{inner}}}")
    name, op, word = match.groups()
    value = lookup(name)
    if not op:
        return value or ""
    active = bool(value) if op.startswith(":") else value is not None
    if op.endswith("-"):
        return value if active else expand(word, lookup)
    if op.endswith("+"):
        return expand(word, lookup) if active else ""
    if not active:
        raise ValueError(f"required variable {name} is missing a value: {expand(word, lookup)}")
    return value


def format_line(name, value):
    """NAME='value'. Single-quoted values are literal to Compose (and to sh), so `$`, `"`, `#`,
    backticks and backslashes are safe; a single quote or newline can't be, and a trailing
    backslash would escape the closing quote for Compose, so they're refused."""
    if not NAME.fullmatch(name):
        raise ValueError(f"'{name}' isn't a valid variable name")
    if any(c in value for c in "'\n\r"):
        raise ValueError(f"{name} contains a single quote or newline, which an env file can't hold")
    if value.endswith("\\"):
        raise ValueError(f"{name} ends with a backslash, which an env file can't hold (Compose "
                         "would read it as escaping the closing quote)")
    return f"{name}='{value}'"
