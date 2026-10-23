#!/usr/bin/env python3
"""paperland config: read and change saved preferences. The running shell follows settings.ini itself."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys

HERE = Path(__file__).resolve().parent
SHELL = HERE / "shell.qml"
USAGE = "Usage: paperland config {list|get KEY|set KEY VALUE|unset KEY|reload|path}"


sys.dont_write_bytecode = True  # shared/ is hashed into the build identity
sys.path.insert(0, str(HERE / "shared"))
import settings_ini  # noqa: E402
from settings_ini import Failure, KEYS, settings_path, text_of, saved_values, read_lines  # noqa: E402


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


def changes(key, value):
    result = {key: value}
    result.update(KEYS[key].get("implies", {}).get(text_of(value), {}))
    return result


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
        # The running shell applies the file change itself; migration is a no-op once it has recorded the upgrade.
        with settings_ini.locked(settings_path()):
            path = settings_path()
            settings_ini.check_pair(path, changes(key, value))
            updates = {**migration(saved_values(read_lines(path))), **changes(key, value)}
            if verb == "unset":
                updates[key] = None
            settings_ini.edit(path, updates, hold=False)
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
