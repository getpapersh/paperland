#!/usr/bin/env python3
"""paperland config: read and change saved preferences, live through IPC when running."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
SHELL = HERE / "shell.qml"
USAGE = "Usage: paperland config {list|get KEY|set KEY VALUE|unset KEY|reload|path}"


class Failure(Exception):
    pass


def load_registry():
    text = (HERE / "SettingsRegistry.js").read_text()
    match = re.search(r"// BEGIN registry\s*var KEYS = (\{.*?\});\s*// END registry", text, re.S)
    return json.loads(match.group(1))


KEYS = load_registry()


def settings_path():
    state = os.environ.get("XDG_STATE_HOME") or str(Path(os.environ.get("HOME") or Path.home()) / ".local/state")
    return Path(state) / "paperland/settings.ini"


# Mirrors parse/changes in SettingsRegistry.js; tests run both against the same cases.
def known(key):
    if key not in KEYS:
        raise Failure(f"Unknown setting: {key}. Known settings: {', '.join(KEYS)}")
    return KEYS[key]


def parse(key, text):
    spec, value = known(key), None
    if spec["type"] == "bool":
        if text in ("true", "false"):
            value = text == "true"
    elif spec["type"] == "int":
        if re.fullmatch(r"-?[0-9]+", text) and spec["min"] <= int(text) <= spec["max"]:
            value = int(text)
    elif text in spec["values"]:
        value = text
    if value is None:
        allowed = {"bool": "true or false",
                   "int": f"an integer from {spec.get('min')} through {spec.get('max')}"}.get(spec["type"]) or ", ".join(spec["values"])
        raise Failure(f"{key} must be {allowed}; got {json.dumps(text)}")
    return value


def text_of(value):
    return ("true" if value else "false") if isinstance(value, bool) else str(value)


def changes(key, value):
    result = {key: value}
    result.update(KEYS[key].get("implies", {}).get(text_of(value), {}))
    return result


# settings.ini is QSettings' INI file; registry keys live in [General] as key=value.
def read_lines(path):
    try:
        return path.read_text(errors="surrogateescape").splitlines(keepends=True)
    except FileNotFoundError:
        return []


def general_span(lines):
    start = next((i + 1 for i, line in enumerate(lines) if line.strip() == "[General]"), None)
    if start is None:
        return None, None
    end = next((i for i in range(start, len(lines)) if lines[i].lstrip().startswith("[")), len(lines))
    return start, end


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
            if key in KEYS and key in values:
                raise Failure(f"settings.ini has more than one {key} entry; remove the extra line. Nothing was changed.")
            raw = raw.strip()
            values[key] = raw[1:-1] if len(raw) >= 2 and raw[0] == raw[-1] == '"' else raw
    return values


def migration(saved):
    """Mirrors shell.qml migrateSettings for a file the shell has not upgraded yet,
    so an offline choice is not replaced by that upgrade at the next start."""
    if re.fullmatch(r"[0-9]+", saved.get("settingsVersion", "")) and int(saved["settingsVersion"]) >= 1:
        return {}
    result = {"settingsVersion": 1, "peek": saved.get("pinned", "true") != "true"}
    seconds = saved.get("autoHideSeconds", "")
    if re.fullmatch(r"[0-9]+", seconds) and 1 <= int(seconds) <= 60:
        result["peekSeconds"] = int(seconds)
    return result


def edit(path, updates):
    """Atomically writes updates ({key: value or None to remove}), leaving other lines intact."""
    lines = read_lines(path)
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
                section.append(f"{key}={text_of(value)}\n")
        else:
            section.append(line)
    while section and not section[-1].strip():
        section.pop()
    section += [f"{key}={text_of(value)}\n" for key, value in pending.items() if value is not None]
    if end < len(lines):
        section.append("\n")
    text = "".join(lines[:start] + section + lines[end:])
    path.parent.mkdir(parents=True, exist_ok=True)
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


def shell_process_running():
    proc = Path("/proc")
    if not proc.is_dir():
        raise Failure("Could not find quickshell to tell whether Paperland is running; nothing was changed.")
    for cmdline in proc.glob("[0-9]*/cmdline"):
        try:
            args = cmdline.read_bytes().split(b"\0")
        except OSError:
            continue
        if os.fsencode(str(SHELL)) in args:
            raise Failure(f"Paperland is running (process {cmdline.parent.name}) but quickshell is not on PATH; "
                          "nothing was changed.")
    return False


def running():
    """True or False only when Quickshell says so; anything else could hide a live shell
    that would overwrite an offline edit, so it stops the command instead."""
    try:
        result = subprocess.run(["quickshell", "list", "-j", "-p", str(SHELL)], text=True, capture_output=True, timeout=5)
    except FileNotFoundError:
        # A shell started with another PATH can still be running; look for it directly.
        return shell_process_running()
    except (OSError, subprocess.TimeoutExpired) as error:
        raise Failure(f"Could not tell whether Paperland is running ({error}); nothing was changed.")
    output = result.stdout.strip()
    if result.returncode == 0:
        # Quickshell 0.3 prints this text for an empty list even with --json.
        if output.startswith("No running instances") or output == "[]":
            return False
        try:
            instances = json.loads(output)
            if isinstance(instances, list) and instances and all(isinstance(i, dict) and "pid" in i for i in instances):
                return True
        except ValueError:
            pass
    raise Failure("Could not tell whether Paperland is running; nothing was changed. "
                  + (result.stdout + result.stderr).strip())


def ipc(function, *args):
    try:
        result = subprocess.run(["quickshell", "ipc", "-p", str(SHELL), "call", "--", "paperland", function, *args],
                                text=True, capture_output=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise Failure(f"Paperland did not answer {function}: {error}")
    try:
        reply = json.loads(result.stdout)
    except ValueError:
        # An instance started before this update has no config functions.
        raise Failure(f"Paperland is running but did not answer {function}; restart it if it predates this command. "
                      + (result.stdout + result.stderr).strip())
    if isinstance(reply, dict) and reply.get("ok") is False:
        raise Failure(reply.get("detail") or reply.get("error") or "Paperland rejected the change")
    return reply


def effective():
    if running():
        return ipc("configList")
    saved = saved_values(read_lines(settings_path()))
    saved.update({key: text_of(value) for key, value in migration(saved).items()})
    values = {}
    for key, raw in saved.items():
        if key in KEYS:
            try:
                values[key] = parse(key, raw)
            except Failure as error:
                print(f"warning: ignoring saved {error}", file=sys.stderr)
    return {key: values.get(key, spec["default"]) for key, spec in KEYS.items()}


def main(argv):
    verb, args = (argv[0], argv[1:]) if argv else ("", [])
    arity = {"list": 0, "get": 1, "set": 2, "unset": 1, "reload": 0, "path": 0}
    if verb not in arity or len(args) != arity[verb]:
        print(USAGE, file=sys.stderr)
        return 2
    if verb == "path":
        print(settings_path())
    elif verb == "list":
        for key, value in effective().items():
            print(f"{key} = {text_of(value)}")
    elif verb == "get":
        known(args[0])
        print(text_of(effective()[args[0]]))
    elif verb in ("set", "unset"):
        key = args[0]
        value = parse(key, args[1]) if verb == "set" else known(key)["default"]
        if running():
            ipc("configSet", key, args[1]) if verb == "set" else ipc("configUnset", key)
        else:
            path = settings_path()
            updates = {**migration(saved_values(read_lines(path))), **changes(key, value)}
            if verb == "unset":
                updates[key] = None
            edit(path, updates)
    elif not running():
        print("Paperland is not running; saved settings load when it starts.", file=sys.stderr)
    else:
        reply = ipc("configReload")
        print("reloaded")
        for error in reply.get("errors", []):
            print(f"  warning [{error['key']}]: {error['detail']}; kept the current value")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Failure as error:
        print(error, file=sys.stderr)
        sys.exit(1)
