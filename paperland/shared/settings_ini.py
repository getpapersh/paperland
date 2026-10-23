#!/usr/bin/env python3
"""The one writer for settings.ini, shared by `paperland config`, Settings Save and the shell.

Every write holds an exclusive lock on settings.ini.lock for its whole read-modify-write and
replaces the file atomically, so two writers cannot lose each other's keys. Entries this module
does not know, comments and other sections stay byte for byte. The shell runs
`settings_ini.py apply JSON` with an object of typed updates.
"""

from contextlib import contextmanager, nullcontext
import fcntl
import json
import os
from pathlib import Path
import re
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


class Failure(Exception):
    pass


def _block(text, name, variable):
    match = re.search(rf"// BEGIN {name}\s*var {variable} = (\{{.*?\}});\s*// END {name}", text, re.S)
    return json.loads(match.group(1))


_registry = (ROOT / "SettingsRegistry.js").read_text()
KEYS = _block(_registry, "registry", "KEYS")
INTERNAL = _block(_registry, "internal", "INTERNAL")
KNOWN = {**KEYS, **INTERNAL}


def settings_path():
    state = os.environ.get("XDG_STATE_HOME") or str(Path(os.environ.get("HOME") or Path.home()) / ".local/state")
    return Path(state) / "paperland/settings.ini"


def text_of(value):
    return ("true" if value else "false") if isinstance(value, bool) else str(value)


def quoted(text):
    """Qt's INI quoting, so Qt-era readers and this reader see the same string."""
    if text == "" or not (re.search(r'[;,="\\\x00-\x1f]', text) or text != text.strip()):
        return text
    escaped = text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t").replace("\r", "\\r")
    return f'"{escaped}"'


def value_text(key, value):
    return quoted(value) if KNOWN.get(key, {}).get("type") in ("string", "json") else text_of(value)


def validate(key, value):
    """Checks a typed value against the registry; returns it or raises Failure."""
    spec = KNOWN.get(key)
    if spec is None:
        raise Failure(f"Unknown setting: {key}")
    kind = spec["type"]
    ok = False
    if kind == "bool":
        ok = isinstance(value, bool)
    elif kind == "int":
        ok = type(value) is int and spec.get("min", value) <= value <= spec.get("max", value)
    elif kind == "choice":
        ok = value in spec["values"]
    elif kind == "string":
        ok = isinstance(value, str)
    elif kind == "json":
        try:
            parsed = json.loads(value) if isinstance(value, str) else None
            ok = isinstance(parsed, dict) and all(isinstance(v, str) for v in parsed.values())
        except ValueError:
            pass
    if not ok:
        raise Failure(f"Invalid value for {key}: {json.dumps(value)}")
    return value


def read_lines(path):
    try:
        return path.read_text(errors="surrogateescape").splitlines(keepends=True)
    except FileNotFoundError:
        return []


def general_span(lines):
    """Line range of the [General] entries. Like Qt, entries before any section header belong to it."""
    first_header = next((i for i, line in enumerate(lines) if line.lstrip().startswith("[")), len(lines))
    explicit = next((i + 1 for i, line in enumerate(lines) if line.strip() == "[General]"), None)
    leading = any("=" in line and not line.lstrip().startswith((";", "#")) for line in lines[:first_header])
    if explicit is not None and leading:
        raise Failure("settings.ini has entries before its [General] section; merge them. Nothing was changed.")
    if explicit is None:
        return (0, first_header) if leading else (None, None)
    end = next((i for i in range(explicit, len(lines)) if lines[i].lstrip().startswith("[")), len(lines))
    return explicit, end


def saved_values(lines):
    # Qt merges repeated sections and the last copy wins, so an edit to the first would not stick.
    if sum(line.strip() == "[General]" for line in lines) > 1:
        raise Failure("settings.ini has more than one [General] section; merge them. Nothing was changed.")
    start, end = general_span(lines)
    values = {}
    for line in lines[start:end] if start is not None else []:
        key, sep, raw = line.partition("=")
        key = key.strip()
        if sep:
            # An edit would replace one copy while another still decides the value.
            if key in KNOWN and key in values:
                raise Failure(f"settings.ini has more than one {key} entry; remove the extra line. Nothing was changed.")
            raw = raw.strip()
            values[key] = raw[1:-1] if len(raw) >= 2 and raw[0] == raw[-1] == '"' else raw
    return values


def render(text, updates):
    """Returns settings.ini text with updates ({key: value or None to remove}) applied."""
    lines = text.splitlines(keepends=True)
    saved_values(lines)
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    start, end = general_span(lines)
    if start is None:
        lines += ["[General]\n"]
        start = end = len(lines)
    pending = dict(updates)
    section = []
    for line in lines[start:end]:
        key = line.partition("=")[0].strip()
        if "=" in line and key in pending:
            value = pending.pop(key)
            if value is not None:
                section.append(f"{key}={value_text(key, value)}\n")
        else:
            section.append(line)
    while section and not section[-1].strip():
        section.pop()
    section += [f"{key}={value_text(key, value)}\n" for key, value in pending.items() if value is not None]
    if end < len(lines):
        section.append("\n")
    return "".join(lines[:start] + section + lines[end:])


@contextmanager
def locked(path):
    """Holds the exclusive writer lock beside settings.ini; waits for another writer to finish."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path.with_name(path.name + ".lock"), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def write_atomic(path, text):
    fd, temporary = tempfile.mkstemp(prefix=".settings-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", errors="surrogateescape") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        if path.exists():
            os.chmod(temporary, path.stat().st_mode & 0o777)
        os.replace(temporary, path)
    except BaseException:
        os.unlink(temporary)
        raise


def edit(path, updates, hold=True):
    """Atomically applies updates, leaving other lines intact. `hold` False means the caller owns the lock."""
    with locked(path) if hold else nullcontext():
        before = "".join(read_lines(path))
        write_atomic(path, render(before, updates))


def check_pair(path, updates):
    """Pinned and Peek are exclusive modes: refuses an update that would leave both true. Call under the lock."""
    if "pinned" in updates or "peek" in updates:
        saved = saved_values(read_lines(path))
        merged = {k: text_of(updates[k]) if k in updates else saved.get(k) for k in ("pinned", "peek")}
        if merged["pinned"] == "true" and merged["peek"] == "true":
            raise Failure("pinned and peek cannot both be true")


def apply(updates):
    """Validated, coupled write for the shell."""
    for key, value in updates.items():
        validate(key, value)
    path = settings_path()
    with locked(path):
        check_pair(path, updates)
        edit(path, updates, hold=False)


def main(argv):
    if not argv or argv[0] != "apply" or len(argv) > 2:
        print("Usage: settings_ini.py apply [JSON]  (a JSON object of updates, from the argument or stdin)", file=sys.stderr)
        return 2
    try:
        updates = json.loads(argv[1]) if len(argv) == 2 else json.load(sys.stdin)
        if not isinstance(updates, dict):
            raise Failure("Updates must be a JSON object")
        apply(updates)
    except (Failure, ValueError, OSError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
