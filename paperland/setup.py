#!/usr/bin/env python3
"""Install Paperland and explicitly configure user-owned Hyprland files."""

import argparse
from contextlib import contextmanager, nullcontext
import difflib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import uuid

INSTALL_MARKER = "Paperland CLI installation v1\n"
CONFIG_HEADER = "-- Paperland setup (generated; edit with paperland setup)\n"
BEGIN = "-- BEGIN Paperland setup\n"
END = "-- END Paperland setup\n"
OWNED = "hypr/paperland.lua"
LEGACY = "hypr/paperland-setup.lua"
NAMES = "hypr/paperland-workspace-names.lua"
DESKTOP_DIRECTIONS = "hypr/paperland-desktop-directions.lua"
DESKTOP_HEADER = "-- Paperland Desktop directions (generated; edit with paperland setup)\n"
MODULES = {
    "preview_control": "native/preview-control.lua",
    "centering": "lua/canvas-actions.lua",
    "strip_focus": "lua/strip-focus.lua",
    "monitor_direction": "lua/monitor-direction.lua",
}
STRIP_CHORD = "SUPER + CTRL"
STAGE_FIRST = ("Symlinked main config needs a manual include. Apply setup first: it writes "
               "paperland.lua, then prints the exact lines to paste.")
BAR_PANEL_COMMAND = "omarchy-shell -q shell togglePanelAt right "


class SetupError(Exception):
    pass


class SetupBusy(SetupError):
    pass


class NativeDirectionPending(SetupError):
    pass


def root(variable, fallback):
    path = Path(os.environ.get(variable) or fallback)
    if not path.is_absolute() or any(ord(c) < 32 for c in str(path)):
        raise SetupError(f"{variable} must be an absolute path without control characters")
    return path


def paths():
    home = root("HOME", str(Path.home()))
    config = root("XDG_CONFIG_HOME", str(home / ".config"))
    data = root("XDG_DATA_HOME", str(home / ".local/share"))
    state = root("XDG_STATE_HOME", str(home / ".local/state"))
    return home, config, data, state


def run(args):
    try:
        result = subprocess.run(args, text=True, capture_output=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise SetupError(f"Could not run {args[0]}: {error}") from error
    if result.returncode:
        raise SetupError(f"{' '.join(args[:2])} failed: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout.strip()


def build_input_bridge(source, staging):
    """Build the optional compositor bridge against the installed Hyprland headers."""
    compiler = shutil.which("c++")
    if not compiler:
        print("Paperland input bridge unavailable: C++ compiler not found.", file=sys.stderr)
        return
    try:
        flags = shlex.split(run(["pkg-config", "--cflags", "hyprland", "lua"]))
        libs = shlex.split(run(["pkg-config", "--libs", "lua"]))
        header = next((Path(flag[2:]) / "src/version.h" for flag in flags
                       if flag.startswith("-I") and (Path(flag[2:]) / "src/version.h").is_file()), None)
        if not header:
            raise SetupError("Hyprland version header not found")
        version_header = header.read_text()
        def version(name):
            match = re.search(r'^#define\s+' + name + r'\s+"([^"]+)"', version_header, re.MULTILINE)
            if not match:
                raise SetupError(f"Hyprland header has no {name}")
            return match.group(1)
        # Match Hyprland's client hash; its dependency components can change under one commit.
        abi = version("GIT_COMMIT_HASH")
        for tag, macro in (("aq", "AQUAMARINE_VERSION"), ("hu", "HYPRUTILS_VERSION"),
                           ("hg", "HYPRGRAPHICS_VERSION"), ("hc", "HYPRCURSOR_VERSION"),
                           ("hlg", "HYPRLANG_VERSION")):
            value = version(macro)
            abi += f"_{tag}_{value.rsplit('.', 1)[0] if '.' in value else value}"
        binary = staging / "native/MinimapInput.so"
        run([compiler, "-std=c++23", "-fPIC", "-shared", str(source / "native/MinimapInput.cpp"),
             "-o", str(binary), *flags, *libs])
        (staging / "native/MinimapInput.version").write_text(abi + "\n")
    except SetupError as error:
        print(f"Paperland input bridge unavailable: {error}", file=sys.stderr)


def regular(path):
    # Replacing a dotfile symlink would break the user's config composition.
    if any(p.is_symlink() for p in [path, *path.parents]):
        raise SetupError(f"Symlinked configuration requires manual integration: {path}")
    if path.exists() and not path.is_file():
        raise SetupError(f"Expected a regular file: {path}")
    return path.read_bytes() if path.exists() else None


def atomic_write(path, data, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".paperland-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(name, mode)
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


@contextmanager
def install_lock(data):
    data.mkdir(parents=True, exist_ok=True)
    path = data / ".paperland-install.lock"
    regular(path)
    with path.open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SetupError("Another Paperland install is publishing files")
        yield


@contextmanager
def setup_lock(state_dir, message="Another Paperland setup is applying changes"):
    """Own the shared setup lock or refuse before any read or write."""
    state_dir.mkdir(parents=True, exist_ok=True)
    regular(state_dir / "setup.lock")
    with (state_dir / "setup.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SetupBusy(message)
        yield


def install(no_setup):
    _, _, data, _ = paths()
    with install_lock(data):
        launcher, _ = install_files()
        if not no_setup:
            try:
                run_setup(parser().parse_args(["setup", "--apply"]), activate_default=True)
            except SetupError as error:
                # Publishing succeeded; a nonzero exit must expose failed activation to scripts.
                raise SetupError(f"Runtime files installed, but monitor direction did not activate: {error}") from error
        report_changed_modules(launcher)
    if not no_setup and sys.stdin.isatty() and sys.stdout.isatty():
        try:
            if choose("Configure shortcuts and desktop integration now?", ["Configure now", "Later"]) == "Configure now":
                run_setup(parser().parse_args(["setup"]))
                return
        except (SetupError, EOFError, KeyboardInterrupt) as error:
            print(f"Paperland is installed; setup did not finish: {str(error) or 'Cancelled'}", file=sys.stderr)
    print(f"Configure later: {shlex.quote(str(launcher))} setup")


def install_files():
    home, _, data, _ = paths()
    source = Path(__file__).resolve().parent
    destination = data / "paperland"
    launcher = home / ".local/bin/paperland"
    marker = destination / ".installed-by-paperland"
    if destination.is_symlink() or (destination.exists() and
            (not marker.is_file() or marker.read_text() != INSTALL_MARKER)):
        raise SetupError(f"Refusing to replace an unowned installation: {destination}")
    if os.path.lexists(launcher) and (not launcher.is_symlink() or
            os.readlink(launcher) != str(destination / "paperland")):
        raise SetupError(f"Launcher already exists; move it aside explicitly to install: {launcher}")
    data.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".paperland-stage-", dir=data))
    previous = None
    published = False
    try:
        for pattern in ("*.qml", "*.js", "qmldir", "paperland", "setup.py", "config.py", "version.txt", "release-notes.json"):
            for file in source.glob(pattern):
                shutil.copy2(file, staging / file.name)
        for directory in ("shared", "native", "lua", "fixtures", "omarchy"):
            shutil.copytree(source / directory, staging / directory)
        build_input_bridge(source, staging)
        (staging / "paperland").chmod(0o755)
        plugin = staging / "plugin"
        plugin.mkdir()
        for name in ("Widget.qml", "manifest.json"):
            shutil.copy2(source / "omarchy" / name, plugin / name)
        (plugin / "paperland").symlink_to("..", target_is_directory=True)
        (staging / ".installed-by-paperland").write_text(INSTALL_MARKER)
        launcher.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists():
            previous = Path(tempfile.mkdtemp(prefix=".paperland-previous-", dir=data))
            previous.rmdir()
            destination.rename(previous)
        staging.rename(destination)
        published = True
        if not launcher.is_symlink():
            launcher.symlink_to(destination / "paperland")
    except BaseException:
        if published:
            destination.rename(staging)
        if previous and previous.exists():
            previous.rename(destination)
        raise
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    print(f"Installed Paperland: {destination}\nLauncher: {launcher}")
    if previous:
        print(f"Previous installation retained: {previous}")
    print("Runtime files published.")
    return launcher, previous


def uninstall():
    home, config, data, state = paths()
    destination = data / "paperland"
    launcher = home / ".local/bin/paperland"
    plugin = config / "omarchy/plugins/json.paperland"
    shell = config / "omarchy/shell.json"
    owned = config / OWNED
    main = config / "hypr/hyprland.lua"
    marker = destination / ".installed-by-paperland"
    if destination.is_symlink() or not marker.is_file() or marker.read_text() != INSTALL_MARKER:
        raise SetupError(f"Uninstall requires an owned installation: {destination}")
    if not launcher.is_symlink() or os.readlink(launcher) != str(destination / "paperland"):
        raise SetupError(f"Launcher is not Paperland-owned: {launcher}")
    if plugin.is_symlink() and os.readlink(plugin) == str(destination / "plugin"):
        raise SetupError(f"Omarchy bar still references this installation; review {plugin} and {shell} before uninstall")
    if shell.is_file():
        bar = shell.read_text(errors="replace")
        if "json.paperland" in bar and (str(launcher) in bar or str(destination / "paperland") in bar):
            raise SetupError(f"Omarchy bar still references this installation; review {shell} before uninstall")
    before_owned = regular(owned)
    if before_owned is None:
        # A files-only install has no desktop contribution to detach.
        main_text = main.read_text(errors="replace") if main.is_file() else ""
        if BEGIN in main_text or str(owned) in main_text or str(destination) in main_text:
            raise SetupError(f"Hyprland still references Paperland; runtime retained: {main}")
        launcher.unlink()
        retained = Path(tempfile.mkdtemp(prefix=".paperland-uninstalled-", dir=data))
        retained.rmdir()
        destination.rename(retained)
        print(f"Uninstalled Paperland. Runtime retained for review: {retained}\nSettings and backups retained: {state / 'paperland'}")
        return
    before_main = regular(main)
    if before_main is None:
        raise SetupError("Main Hyprland config is missing; runtime retained")
    try:
        old = before_owned.decode()
        generated_options(before_owned, str(config / NAMES))
    except (ValueError, KeyError, IndexError, TypeError, SetupError):
        raise SetupError(f"Generated setup was edited; runtime retained: {owned}")
    include = BEGIN + f"dofile({lua(str(owned))})\n" + END
    original = before_main.decode()
    if original.count(include) != 1 or original.count(BEGIN) != 1 or original.count(END) != 1:
        raise SetupError(f"Paperland include was edited or is absent; runtime retained: {main}")
    revision = re.search(r'_G.paperland_setup_revision = "([a-f0-9]+)"', old).group(1)
    if run(["hyprctl", "repl", "return _G.paperland_setup_revision"]) != revision:
        raise SetupError("Active Hyprland config does not match this installation; runtime retained")
    after_main = original.replace(include, "", 1).encode()
    if str(owned) in after_main.decode() or str(destination / MODULES["monitor_direction"]) in after_main.decode():
        raise SetupError("Another reference to Paperland setup remains; runtime retained")
    apply_changes({main: (before_main, after_main)}, None, data, state, None, reload=True)
    if regular(owned) != before_owned or regular(main) != after_main:
        raise SetupError("Config changed after detach; runtime retained for inspection")
    owned.unlink()
    launcher.unlink()
    retained = Path(tempfile.mkdtemp(prefix=".paperland-uninstalled-", dir=data))
    retained.rmdir()
    destination.rename(retained)
    print(f"Uninstalled Paperland. Runtime retained for review: {retained}\nSettings and backups retained: {state / 'paperland'}")


def lua(value):
    return json.dumps(value, ensure_ascii=False)


def lua_table(values):
    return "{" + ",".join(f"[{lua(name)}]={lua(value)}" for name, value in sorted(values.items())) + "}"


def desktop_record(values):
    return (DESKTOP_HEADER + "-- choices: " + json.dumps(values, sort_keys=True) + "\n"
            + "return {" + ",".join(f"[{int(number)}]={lua(value)}" for number, value in
                                     sorted(values.items(), key=lambda item: int(item[0]))) + "}\n").encode()


def read_desktop_record(path):
    before = regular(path)
    if before is None:
        return None, {}
    try:
        values = json.loads(before.decode().splitlines()[1].removeprefix("-- choices: "))
        if not isinstance(values, dict) or any(not re.fullmatch(r"[1-9][0-9]*", number)
                or len(number) > 10 or int(number) > 2147483647
                or value not in ("right", "down") for number, value in values.items()):
            raise ValueError("invalid choices")
        if before != desktop_record(values):
            raise ValueError("modified content")
    except (UnicodeError, ValueError, IndexError, TypeError) as error:
        raise SetupError(f"Refusing to overwrite edited or unowned Desktop direction record: {path}") from error
    return before, values


def validate_monitor_options(options):
    if "monitor_direction" in options and not isinstance(options["monitor_direction"], bool):
        raise SetupError("Invalid saved monitor direction setting")
    overrides = options.get("monitor_direction_overrides", {})
    if not isinstance(overrides, dict) or any(
            not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_.:-]+", name)
            or value not in ("right", "left", "up", "down")
            for name, value in overrides.items()):
        raise SetupError("Invalid saved monitor direction override")


def shortcut(value):
    if value in ("keep", "none"):
        return value
    parts = [part.strip().upper() for part in value.split("+")]
    if len(parts) < 2 or any(p not in ("SUPER", "CTRL", "ALT", "SHIFT") for p in parts[:-1]):
        raise SetupError("Use a modified key such as SUPER + M or SUPER + ALT + M")
    if len(set(parts[:-1])) != len(parts) - 1 or not re.fullmatch(r"[A-Z0-9_]+|CODE:[0-9]+", parts[-1]):
        raise SetupError("Invalid shortcut")
    if parts[-1] in ("SUPER", "CTRL", "ALT", "SHIFT"):
        raise SetupError("Shortcut needs a non-modifier key")
    # code:020 and code:20 are the same key to Hyprland; canonicalize so conflict
    # checks, which compare spellings, cannot be bypassed by leading zeros.
    # Strip as text: int() raises past Python's 4,300-digit conversion limit.
    key = "code:" + (parts[-1][5:].lstrip("0") or "0") if parts[-1].startswith("CODE:") else parts[-1]
    return " + ".join([p for p in ("SUPER", "CTRL", "ALT", "SHIFT") if p in parts[:-1]] + [key])


def shortcut_uses_digit_range(value, modifiers):
    if value == "none":
        return False
    parts = value.split(" + ")
    if parts[:-1] != modifiers:
        return False
    key = parts[-1]
    if re.fullmatch(r"[1-9]", key):
        return True
    match = re.fullmatch(r"code:(\d+)", key)
    return bool(match and match.group(1).lstrip("0") in {str(i) for i in range(10, 19)})


def generated_options(data, names):
    """Options of generated content, raising ValueError when it was edited."""
    old = data.decode()
    options = json.loads(old.splitlines()[1].removeprefix("-- options: "))
    if old != render(options, names):
        raise ValueError("modified content")
    return options


def render(options, names):
    """names is None only to recognize a legacy paperland-setup.lua, which never loaded them."""
    validate_monitor_options(options)
    content = CONFIG_HEADER + "-- options: " + json.dumps(options, ensure_ascii=False, sort_keys=True) + "\n"
    if names is not None:
        # The names writer creates this file on the first rename, then reloads.
        content += (f'\nlocal names = {lua(names)}\nlocal names_file = io.open(names, "r")\n'
                    'if names_file then names_file:close(); dofile(names) end\n')
    command = shlex.quote(options["launcher"])
    if options["shortcut"] != "none":
        key = lua(options["shortcut"])
        content += f'hl.unbind({key})\nhl.bind({key}, hl.dsp.exec_cmd({lua(command + " start-hidden && " + command + " toggle")}), {{ description = "Paperland minimap" }})\n'
    if options["resize"] != "system":
        expression = ('string.format("colresize %+.8f", fraction)' if options["resize"] == "incremental"
                      else '(pixels > 0 and "colresize +conf" or "colresize -conf")')
        content += '''
local function resize_width(pixels, fraction)
  local window = hl.get_active_window()
  if not window then return end
  local workspace = window.workspace
  -- Layout belongs to the focused window's workspace, including special ones.
  if not window.floating and window.fullscreen == 0
      and workspace and workspace.tiled_layout == "scrolling" then
    hl.dispatch(hl.dsp.layout(EXPRESSION))
  else
    hl.dispatch(hl.dsp.window.resize({ x = pixels, y = 0, relative = true }))
  end
end
for _, step in ipairs({
  { modifiers = "SUPER", pixels = 100, fraction = 0.05 },
  { modifiers = "SUPER + ALT", pixels = 25, fraction = 0.0125 },
  { modifiers = "SUPER + CTRL", pixels = 300, fraction = 0.15 },
}) do
  for _, direction in ipairs({
    { key = "code:20", sign = -1, label = "Paperland: decrease window width" },
    { key = "code:21", sign = 1, label = "Paperland: increase window width" },
  }) do
    local keys = step.modifiers .. " + " .. direction.key
    local pixels, fraction = step.pixels * direction.sign, step.fraction * direction.sign
    hl.unbind(keys)
    hl.bind(keys, function() resize_width(pixels, fraction) end, { description = direction.label })
  end
end
'''.replace("EXPRESSION", expression)
    if options["autostart"] == "on":
        content += f'\nhl.on("hyprland.start", function()\n  hl.dispatch(hl.dsp.exec_cmd({lua(command + " start-hidden")}))\nend)\n'
    if options.get("preview_control", False):
        adapter = str(Path(options["launcher"]).parent / MODULES["preview_control"])
        content += f'\ndofile({lua(adapter)})\n'
    if options.get("centering", "none") != "none":
        module = str(Path(options["launcher"]).parent / MODULES["centering"])
        content += (f'\n_G.paperland_centering_shortcut = {lua(options["centering"])}\n'
                    f'dofile({lua(module)})\n')
    if options.get("strip_chord") == STRIP_CHORD:
        for digit in range(1, 10):
            code = digit + 9
            original = f"SUPER + CTRL + code:{code}"
            content += f'\nhl.unbind({lua(original)})\n'
            if options["bar_panels"] == "relocate":
                relocated = f"SUPER + CTRL + ALT + code:{code}"
                command = BAR_PANEL_COMMAND + str(digit)
                content += (f'hl.unbind({lua(relocated)})\n'
                            f'hl.bind({lua(relocated)}, hl.dsp.exec_cmd({lua(command)}), '
                            f'{{ description = {lua("Bar panel " + str(digit))} }})\n')
        module = str(Path(options["launcher"]).parent / MODULES["strip_focus"])
        content += (f'\n_G.paperland_strip_chord = {lua(STRIP_CHORD)}\n'
                    f'_G.paperland_strip_launcher = {lua(options["launcher"])}\n'
                    f'dofile({lua(module)})\n')
    if options.get("monitor_direction") is True:
        module = str(Path(options["launcher"]).parent / MODULES["monitor_direction"])
        content += (f'\n_G.paperland_monitor_direction_options = '
                    f'{{ enabled = true, overrides = {lua_table(options.get("monitor_direction_overrides", {}))} }}\n')
        if options.get("desktop_direction_record"):
            record = options["desktop_direction_record"]
            content += (f'local desktop_record = {lua(record)}\n'
                        'local desktop_file = io.open(desktop_record, "r")\n'
                        'if desktop_file then desktop_file:close(); '
                        '_G.paperland_monitor_direction_options.desktops = dofile(desktop_record) end\n')
        content += f'dofile({lua(module)})\n'
    if "minimap_blur" in options:
        content += ('\nhl.layer_rule({ name = "paperland-minimap-blur", '
                    'match = { namespace = "^paperland-minimap$" }, blur = '
                    + ("true" if options["minimap_blur"] else "false") + ', ignore_alpha = 0 })\n')
    # A clean configerrors response alone does not prove this include was loaded.
    revision = hashlib.sha256(content.encode()).hexdigest()
    return content + f'\n_G.paperland_setup_revision = "{revision}"\n'


def module_hashes(options, launcher):
    """Digest every module this config dofiles, so an update cannot change a
    binding silently. Recorded in options, never recomputed inside render():
    render(previous) must keep reproducing the file already on disk, or a
    routine runtime update would look like a manual edit and block setup."""
    loaded = {}
    if options.get("preview_control", False):
        loaded["preview_control"] = MODULES["preview_control"]
    if options.get("centering", "none") != "none":
        loaded["centering"] = MODULES["centering"]
    if options.get("strip_chord") == STRIP_CHORD:
        loaded["strip_focus"] = MODULES["strip_focus"]
    if options.get("monitor_direction") is True:
        loaded["monitor_direction"] = MODULES["monitor_direction"]
    digests = {}
    for name, relative in loaded.items():
        path = launcher.parent / relative
        # render() emits an unconditional dofile, so a missing module would
        # export Lua that cannot load; refuse rather than preview broken config.
        if not path.is_file():
            raise SetupError(f"Installed module is missing: {path}; run paperland install")
        digests[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    return digests


def changed_modules(options, launcher):
    recorded = options.get("modules", {})
    return sorted(name for name, digest in module_hashes(options, launcher).items()
                  if name in recorded and recorded[name] != digest)


def report_changed_modules(launcher):
    """Warn at install time too: the generated dofile picks up a replaced module
    on the next compositor reload, before any later setup run could report it."""
    _, config, data, _ = paths()
    owned = config / OWNED if (config / OWNED).exists() else config / LEGACY
    try:
        options = json.loads(owned.read_text().splitlines()[1].removeprefix("-- options: "))
        # launcher is the ~/.local/bin symlink; modules live beside the runtime.
        changed = changed_modules(options, data / "paperland/paperland")
    except (OSError, ValueError, IndexError, AttributeError, SetupError):
        return
    if changed:
        print("This update changes configured actions; they take effect on the next Hyprland reload:")
        for name in changed:
            print(f"  {MODULES[name]}")
        print("Rerun setup to refresh the generated config.")
        print(f"Review with: {shlex.quote(str(launcher))} setup --dry-run")


def choose(title, options):
    if shutil.which("gum"):
        result = subprocess.run(["gum", "choose", "--header", title, "--", *options], text=True, stdout=subprocess.PIPE)
        if result.returncode or result.stdout.strip() not in options:
            raise SetupError("Setup cancelled; no configuration changes applied")
        return result.stdout.strip()
    print(title)
    for number, option in enumerate(options, 1):
        print(f"  {number}. {option}")
    while True:
        answer = input("Choose a number (Enter cancels): ").strip()
        if not answer:
            raise SetupError("Setup cancelled; no configuration changes applied")
        if answer.isdigit() and 1 <= int(answer) <= len(options):
            return options[int(answer) - 1]


def wizard(args):
    print("Paperland setup\nChoose optional changes. Nothing is written until the final review.")
    selected = choose("Open the minimap", ["Keep current shortcut", "Super + M", "Choose another shortcut", "Remove Paperland's managed shortcut"])
    args.shortcut = {"Keep current shortcut": "keep", "Super + M": "SUPER + M", "Remove Paperland's managed shortcut": "none"}.get(selected)
    while args.shortcut is None:
        answer = input("Shortcut (for example SUPER + ALT + M; Enter cancels): ").strip()
        if not answer:
            raise SetupError("Setup cancelled; no configuration changes applied")
        try:
            args.shortcut = shortcut(answer)
        except SetupError as error:
            print(error)
    print("Scrolling resize uses its primary axis: width horizontally, height vertically.\nOther layouts and floating windows retain pixel resizing.")
    args.resize = {"Keep current resizing": "keep", "Incremental column sizing (5%; Alt 1.25%; Ctrl 15%)": "incremental", "Cycle configured column sizes": "presets", "Remove Paperland's managed resize bindings": "system"}[choose("Resize shortcuts", ["Keep current resizing", "Incremental column sizing (5%; Alt 1.25%; Ctrl 15%)", "Cycle configured column sizes", "Remove Paperland's managed resize bindings"])]
    print("Centered browsing keeps the focused column in the middle; packed scrolls it the\nminimum distance into view. The switch takes effect on the next focus change.")
    args.centering = {"Keep current centering shortcut": "keep", "Super + Shift + C": "SUPER + SHIFT + C", "Remove Paperland's managed centering shortcut": "none"}.get(
        choose("Toggle column centering", ["Keep current centering shortcut", "Super + Shift + C", "Choose another shortcut", "Remove Paperland's managed centering shortcut"]))
    while args.centering is None:
        answer = input("Centering shortcut (for example SUPER + SHIFT + C; Enter cancels): ").strip()
        if not answer:
            raise SetupError("Setup cancelled; no configuration changes applied")
        try:
            args.centering = shortcut(answer)
        except SetupError as error:
            print(error)
    args.strip_chord = {
        "Keep current strip focus choice": "keep",
        "Super + Ctrl + 1–9 (recommended)": STRIP_CHORD,
        "Remove numbered strip focus": "none",
    }[choose("Numbered strip focus", [
        "Keep current strip focus choice", "Super + Ctrl + 1–9 (recommended)",
        "Remove numbered strip focus",
    ])]
    if args.strip_chord == STRIP_CHORD:
        args.bar_panels = {
            "Relocate Bar panel shortcuts to Super + Ctrl + Alt + 1–9 (recommended)": "relocate",
            "Drop the Bar panel shortcuts": "drop",
        }[choose("Super + Ctrl Bar panel shortcuts", [
            "Relocate Bar panel shortcuts to Super + Ctrl + Alt + 1–9 (recommended)",
            "Drop the Bar panel shortcuts",
        ])]
    args.autostart = {"Keep current startup behavior": "keep", "Start Paperland hidden at login": "on", "Remove Paperland's managed startup action": "off"}[choose("Startup", ["Keep current startup behavior", "Start Paperland hidden at login", "Remove Paperland's managed startup action"])]
    if (paths()[1] / "omarchy/shell.json").is_file():
        args.omarchy_bar = "enable" if choose("Use Paperland in Omarchy Bar?", ["Yes", "No"]) == "Yes" else "keep"


def check_hyprland():
    errors = run(["hyprctl", "configerrors"])
    if errors:
        raise SetupError(f"Hyprland configuration errors:\n{errors}")


def check_monitor_direction_capability():
    version = run(["hyprctl", "version"])
    if not re.search(r"\bHyprland 0\.56\.2\b", version):
        raise SetupError("Monitor direction requires verified Hyprland 0.56.2; use paperland setup --monitor-direction off --apply to keep it disabled")


def direction_conflicts(main, skip):
    """Text-scan literal dofile and require chains; dynamic includes need review."""
    pending = [main]
    visited = set()
    found = []
    literal = re.compile(r'''dofile\(\s*["']([^"']+)["']\s*\)''')
    home = re.compile(r'''dofile\(\s*os\.getenv\(["']HOME["']\)\s*\.\.\s*["']([^"']+)["']\s*\)''')
    required = re.compile(r'''require\(\s*["']([A-Za-z_][\w]*(?:\.[A-Za-z_][\w]*)*)["']\s*\)''')
    omarchy = Path(os.environ.get("OMARCHY_PATH") or "/usr/share/omarchy")
    while pending:
        path = pending.pop()
        path = path.resolve()
        if path in visited or path in {p.resolve() for p in skip} or not path.is_file():
            continue
        visited.add(path)
        lines = path.read_text(errors="replace").splitlines()
        rule_until = -1
        for number, line in enumerate(lines, 1):
            if "workspace_rule" in line:
                rule_until = number + 12
            if number <= rule_until and re.search(r"\bdirection\s*=", line):
                found.append((path, number))
            for match in literal.finditer(line):
                child = Path(match.group(1))
                pending.append(child if child.is_absolute() else path.parent / child)
            for match in home.finditer(line):
                pending.append(Path.home() / match.group(1).lstrip("/"))
            for match in required.finditer(line):
                relative = Path(*match.group(1).split("."))
                for base in (main.parent.parent, main.parent, path.parent, omarchy):
                    for candidate in (base / relative.with_suffix(".lua"), base / relative / "init.lua"):
                        if candidate.is_file():
                            pending.append(candidate)
    return found


def bar_change(config, data, launcher, mode, scratchpad):
    shell_path = config / "omarchy/shell.json"
    if mode == "enable":
        action = (f'add or update a json.paperland item with executable {json.dumps(str(launcher))}'
                  + (f' and scratchpad {str(scratchpad == "show").lower()}' if scratchpad != "keep" else "")
                  + ", replacing omarchy.workspaces in place and preserving other widgets")
    elif mode == "disable":
        action = "remove the owned json.paperland item and restore omarchy.workspaces at its position only if none exists"
    else:
        action = f'set json.paperland scratchpad to {str(scratchpad == "show").lower()} and preserve all other settings'
    try:
        before = regular(shell_path)
    except SetupError as error:
        link = next((path for path in (shell_path, *shell_path.parents) if path.is_symlink()), None)
        target = (link.parent / os.readlink(link)).resolve() if link else shell_path
        destination = f"tracked target {target} (linked by {link})" if link else str(shell_path)
        return shell_path, None, None, None, f"Do not write {shell_path} automatically ({error}). Edit {destination}: {action}."
    if before is None:
        raise SetupError(f"No Omarchy bar config at {shell_path}; Bar options require shell.json")
    try:
        shell = json.loads(before)
        sections = shell["bar"]["layout"]
        if not all(isinstance(sections[k], list) for k in ("left", "center", "right")):
            raise ValueError("Expected left/center/right lists")
        if any(widget == "json.paperland" for key in ("left", "center", "right") for widget in sections[key]):
            raise ValueError("String json.paperland entries need manual ownership review")
        entries = [item for key in ("left", "center", "right") for item in sections[key]
                   if isinstance(item, dict) and item.get("id") == "json.paperland"]
        link = config / "omarchy/plugins/json.paperland"
        if len(entries) > 1:
            raise ValueError("Multiple json.paperland items require manual review")
        existing = entries[0] if entries else None
        plugin_owned = link.is_symlink() and os.readlink(link) == str(data / "paperland/plugin")
        if existing and existing.get("executable") not in (None, str(launcher)):
            raise ValueError("Existing json.paperland item has an unowned executable")
        if existing and mode == "disable" and existing.get("executable") is None and not plugin_owned:
            raise ValueError("Existing json.paperland item has no installer-owned executable")
        if mode == "enable" or scratchpad != "keep":
            item = {**(existing or {}), "id": "json.paperland", "executable": str(launcher)}
            if scratchpad != "keep":
                item["scratchpad"] = scratchpad == "show"
        else:
            item = None
        workspace_exists = any((widget.get("id") if isinstance(widget, dict) else widget) == "omarchy.workspaces"
                                for key in ("left", "center", "right") for widget in sections[key])
        workspace_inserted = False
        inserted = False
        for section in ("left", "center", "right"):
            new = []
            for widget in sections[section]:
                identity = widget.get("id") if isinstance(widget, dict) else widget
                if identity == "json.paperland":
                    if not inserted:
                        if mode == "disable":
                            if not workspace_exists:
                                new.append({"id": "omarchy.workspaces"})
                                workspace_inserted = True
                        elif item:
                            new.append(item)
                        inserted = True
                elif identity == "omarchy.workspaces" and mode == "enable":
                    if not inserted:
                        new.append(item)
                        inserted = True
                elif identity == "omarchy.workspaces" and mode == "disable":
                    if not workspace_inserted:
                        new.append(widget)
                        workspace_inserted = True
                else:
                    new.append(widget)
            sections[section] = new
        if mode == "enable" and not inserted:
            sections["left"].append(item)
        if mode == "disable" and not entries:
            return shell_path, before, before, None, None
    except (ValueError, KeyError, TypeError) as error:
        manual = f"Edit {shell_path} manually: {action}. The current config needs review ({error})."
        return shell_path, None, None, None, manual
    if mode == "enable" and any(p.is_symlink() for p in link.parents):
        manual = f"Edit {shell_path} manually; the plugin parent for {link} is symlinked and must be reviewed."
        return shell_path, None, None, None, manual
    if mode == "enable" and os.path.lexists(link) and (not link.is_symlink() or os.readlink(link) != str(data / "paperland/plugin")):
        manual = f"Edit {shell_path} manually; {link} is not owned by this installer. Move it aside explicitly before enabling integration."
        return shell_path, None, None, None, manual
    after = (json.dumps(shell, indent=2, ensure_ascii=False) + "\n").encode()
    return shell_path, before, after, link if mode == "enable" and not os.path.lexists(link) else None, None


def inventory(options):
    modifiers = {"SUPER": 64, "CTRL": 4, "ALT": 8, "SHIFT": 1}
    masks = {64, 72, 68} if options["resize"] != "system" else set()
    for chord in (options["shortcut"], options.get("centering", "none")):
        if chord != "none":
            masks.add(sum(modifiers[p.strip()] for p in chord.split("+")[:-1]))
    if options.get("strip_chord") == STRIP_CHORD:
        masks.add(68)
        if options.get("bar_panels") == "relocate":
            masks.add(76)
    if not masks:
        return
    try:
        bindings = json.loads(run(["hyprctl", "-j", "binds"]))
        print("Live bindings sharing these modifiers (review before replacement):")
        unknown = 0
        for binding in bindings:
            if binding.get("modmask") not in masks:
                continue
            key = binding.get("key") or binding.get("keycode")
            if not key:
                unknown += 1
            else:
                print(f"  mods={binding.get('modmask')} key={key}: {binding.get('description') or binding.get('dispatcher')}")
        if unknown:
            print(f"  {unknown} bindings have no key identity in Lua IPC; inspect your config or omarchy menu keybindings --print.")
    except (SetupError, ValueError):
        print("Binding inventory unavailable; inspect your config before replacing bindings.")


def show_diff(changes):
    for path, (before, after) in changes.items():
        print("".join(difflib.unified_diff((before or b"").decode().splitlines(True), (after or b"").decode().splitlines(True), fromfile=str(path), tofile=str(path))), end="")



# SettingsRegistry.js is the one list of runtime preferences; config.py reads it the same way.
RUNTIME_KEYS = json.loads(re.search(r"// BEGIN registry\s*var KEYS = (\{.*?\});\s*// END registry",
                                    (Path(__file__).resolve().parent / "SettingsRegistry.js").read_text(), re.S).group(1))
RUNTIME_DEFAULTS = {key: spec["default"] for key, spec in RUNTIME_KEYS.items()}


def runtime_values(before):
    """Read only scalar Paperland preferences; preserve Qt's other INI entries."""
    values = dict(RUNTIME_DEFAULTS)
    general = False
    seen = set()
    for line in (before or b"").decode().splitlines():
        if line.startswith("["):
            general = line == "[General]"
        elif general and "=" in line:
            key, value = line.split("=", 1)
            if key not in values:
                continue
            if key in seen:
                raise SetupError(f"Duplicate runtime preference: {key}")
            seen.add(key)
            default = RUNTIME_DEFAULTS[key]
            if isinstance(default, bool):
                if value not in ("true", "false"):
                    raise SetupError(f"Invalid saved runtime preference: {key}")
                values[key] = value == "true"
            elif isinstance(default, int):
                try:
                    values[key] = int(value)
                except ValueError:
                    raise SetupError(f"Invalid saved runtime preference: {key}")
            else:
                values[key] = value
    return values


def runtime_change(before, selection, baseline):
    try:
        selected, expected = json.loads(selection), json.loads(baseline)
    except (ValueError, TypeError):
        raise SetupError("Runtime preferences and baseline must be JSON objects")
    if not isinstance(selected, dict) or not isinstance(expected, dict) or set(selected) != set(expected):
        raise SetupError("Runtime preferences require a matching baseline")
    current = runtime_values(before)
    limits = {key: (spec["min"], spec["max"]) for key, spec in RUNTIME_KEYS.items() if spec["type"] == "int"}
    for key, value in selected.items():
        if key not in RUNTIME_DEFAULTS or type(value) is not type(RUNTIME_DEFAULTS[key]):
            raise SetupError(f"Invalid runtime preference: {key}")
        if key in limits and not limits[key][0] <= value <= limits[key][1]:
            raise SetupError(f"Runtime preference out of range: {key}")
        if key == "minimapOpacityMode" and value not in ("background", "entire"):
            raise SetupError("Invalid minimap opacity mode")
        if type(expected[key]) is not type(RUNTIME_DEFAULTS[key]) or current[key] != expected[key]:
            raise SetupError("Runtime preferences changed while editing; reopen Settings before saving")
    if {**current, **selected}["pinned"] and {**current, **selected}["peek"]:
        raise SetupError("Pinned and Peek cannot both be enabled")
    remaining = dict(selected)
    lines, general = [], False
    for line in (before or b"").decode().splitlines(True):
        if line.startswith("["):
            if general:
                lines.extend(f"{key}={str(value).lower()}\n" for key, value in sorted(remaining.items()))
                remaining.clear()
            general = line.strip() == "[General]"
        key = line.partition("=")[0]
        if general and key in remaining:
            line = f"{key}={str(remaining.pop(key)).lower()}\n"
        lines.append(line)
    if not general and remaining:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        lines.append("\n[General]\n")
    elif remaining and lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    lines.extend(f"{key}={str(value).lower()}\n" for key, value in sorted(remaining.items()))
    return "".join(lines).encode()


def settings_dependencies(config, data, launcher):
    """Fingerprint every input the reviewed generated configuration can read."""
    files = [config / name for name in (OWNED, LEGACY, NAMES, DESKTOP_DIRECTIONS, "hypr/hyprland.lua",
                                           "omarchy/shell.json", "omarchy/plugins/json.paperland")]
    files += [launcher.parent / name for name in MODULES.values()]
    files += [launcher.parent / name for name in ("native/MinimapInput.so", "native/MinimapInput.version")]
    files += [launcher, data / "paperland/.installed-by-paperland", Path(__file__)]
    files.append(paths()[3] / "paperland/settings.ini")
    result = {}
    for path in files:
        if path.is_symlink():
            target = os.readlink(path)
            content = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None
            result[str(path)] = ["link", target, content]
        elif path.is_file():
            result[str(path)] = ["file", hashlib.sha256(path.read_bytes()).hexdigest()]
        elif os.path.lexists(path):
            result[str(path)] = ["other"]
        else:
            result[str(path)] = ["absent"]
    return result


def settings_plan(args, changes, plugin_link, config, data, launcher, options, warnings, manual, expected_revision,
                  desktop_choices, retry_native):
    dependencies = settings_dependencies(config, data, launcher)
    files = []
    for path, (before, after) in changes.items():
        diff = "".join(difflib.unified_diff((before or b"").decode().splitlines(True),
                                             (after or b"").decode().splitlines(True),
                                             fromfile=str(path), tofile=str(path)))
        files.append({"path": str(path), "diff": diff})
    selection = {name: getattr(args, name) for name in ("shortcut", "resize", "autostart",
        "centering", "strip_chord", "bar_panels", "omarchy_bar", "monitor_direction",
        "omarchy_bar_scratchpad", "monitor_direction_override", "desktop_direction", "replace_bindings",
        "runtime_preferences", "runtime_baseline", "minimap_blur")}
    bar_path = config / "omarchy/shell.json"
    bar_after = changes.get(bar_path, (None, None))[1]
    if bar_after is None:
        try:
            bar_after = regular(bar_path)
        except SetupError:
            # Read a linked target for display only; bar_change still refuses writes.
            bar_after = bar_path.read_bytes() if bar_path.is_file() else None
    bar_effective = bar_scratchpad = None
    if bar_after is not None:
        try:
            layout = json.loads(bar_after)["bar"]["layout"]
            item = next((widget for section in ("left", "center", "right") for widget in layout[section]
                         if isinstance(widget, dict) and widget.get("id") == "json.paperland"), None)
            bar_effective = item is not None
            bar_scratchpad = item.get("scratchpad", True) if item else None
        except (ValueError, KeyError, TypeError):
            pass
    identity = {"selection": selection, "dependencies": dependencies,
                "after": {str(path): None if after is None else hashlib.sha256(after).hexdigest()
                          for path, (_, after) in changes.items()},
                "plugin_link": str(plugin_link) if plugin_link else None}
    token = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
    effective = {name: options.get(name) for name in ("autostart", "shortcut", "resize",
                                                       "centering", "strip_chord", "bar_panels", "monitor_direction",
                                                       "monitor_direction_overrides")}
    try:
        active_desktops, direction_available, _ = active_desktop_directions()
    except SetupError:
        active_desktops, direction_available = None, False
    if not options.get("monitor_direction"):
        try:
            direction_available = run(["hyprctl", "repl", "return hl.plugin and hl.plugin.paperland and "
                "type(hl.plugin.paperland.effective_direction) == 'function' or false"]) == "true"
        except SetupError:
            direction_available = False
    effective["runtime_preferences"] = runtime_values(regular(paths()[3] / "paperland/settings.ini"))
    effective["minimap_blur"] = options.get("minimap_blur", False)
    try:
        effective["compositor_blur"] = json.loads(run(["hyprctl", "getoption", "decoration:blur:enabled", "-j"]))["bool"]
    except (SetupError, ValueError, KeyError):
        effective["compositor_blur"] = None
    effective.update(omarchy_bar=bar_effective, bar_scratchpad=bar_scratchpad,
                     bar_available=bar_path.is_file(), desktop_directions=desktop_choices,
                     active_desktop_directions=active_desktops,
                     native_direction_available=direction_available)
    return {"token": token, "files": files, "warnings": warnings,
            "effective": effective,
            "staged": {"omarchy_bar": args.omarchy_bar,
                       "bar_scratchpad": args.omarchy_bar_scratchpad},
            "plugin_link": str(plugin_link) if plugin_link else None,
            "manual": manual,
            "next_action": manual or (("omarchy-shell shell rescanPlugins" if plugin_link else "omarchy-shell shell reloadConfig")
                                      if args.omarchy_bar != "keep" or args.omarchy_bar_scratchpad != "keep" else None),
            "retry_native": retry_native,
            "expected_revision": expected_revision}, dependencies


def settings_result_path(state):
    return state / "paperland/settings-apply.json"


def save_settings_result(state, result):
    atomic_write(settings_result_path(state), (json.dumps(result, indent=2) + "\n").encode())


def process_start(pid):
    try:
        # A reused PID must not keep an interrupted Apply looking live forever.
        return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[19]
    except (OSError, IndexError):
        return None


def settings_refusal_path(state, attempt):
    return state / "paperland" / f"settings-refused-{attempt}.json"


def validate_settings_attempt(attempt):
    if attempt is not None and not re.fullmatch(r"[0-9a-f]{16,64}", attempt):
        raise SetupError("--settings-attempt takes 16 to 64 lowercase hex characters")


def save_settings_refusal(state, attempt, error):
    # A lock loser must not replace the active writer's shared receipt. Reused
    # IDs cannot certify refusal of the earlier writer that owns that ID.
    shared = regular(settings_result_path(state))
    if shared is not None and json.loads(shared).get("attempt_id") == attempt:
        return
    path = settings_refusal_path(state, attempt)
    if regular(path) is None:
        atomic_write(path, (json.dumps({"status": "not-applied", "attempt_id": attempt,
                                      "error": str(error)}) + "\n").encode())


def settings_status(state, locked=False, attempt=None):
    validate_settings_attempt(attempt)
    path = settings_result_path(state)
    before = regular(path)
    result = json.loads(before) if before is not None else {"status": "none"}
    if attempt and result.get("attempt_id") != attempt:
        refused = regular(settings_refusal_path(state, attempt))
        return json.loads(refused) if refused is not None else result
    if result.get("status") not in ("running", "unknown"):
        return result
    if result["status"] == "running" and result.get("pid_start") and process_start(result["pid"]) == result["pid_start"]:
        return result
    if not locked:
        # Reconciliation rewrites the receipt, so it may run only while no Apply
        # owns the lock; a busy lock means a live owner's receipt must stay as-is.
        try:
            with setup_lock(state / "paperland"):
                return settings_status(state, locked=True, attempt=attempt)
        except SetupError:
            return result
    if result.get("phase") == "planning":
        # The writer cannot change configuration before replacing this admission
        # receipt with the prepared plan and its file hashes.
        result["status"] = "not-applied"
        save_settings_result(state, result)
        return result
    observed = {}
    for path_text, hashes in result["files"].items():
        current = regular(Path(path_text))
        observed[path_text] = None if current is None else hashlib.sha256(current).hexdigest()
    all_after = all(observed[path] == hashes["after"] for path, hashes in result["files"].items())
    all_before = all(observed[path] == hashes["before"] for path, hashes in result["files"].items())
    plugin = result.get("plugin_link")
    if plugin:
        all_after &= Path(plugin).is_symlink()
        all_before &= not os.path.lexists(plugin)
    backup = result.get("backup")
    if backup and not Path(backup, "files.json").is_file():
        all_after = all_before = False
    if all_after and result.get("expected_revision"):
        try:
            all_after = run(["hyprctl", "repl", "return _G.paperland_setup_revision"]) == result["expected_revision"]
        except SetupError:
            all_after = False
    result["status"] = ("saved-needs-manual" if result.get("manual") else
                        "saved-needs-rescan" if result.get("needs_rescan") else "applied") if all_after else "not-applied" if all_before else "unknown"
    if all_after and result.get("native_choices"):
        try:
            confirm_desktop_choices(result["native_choices"])
        except NativeDirectionPending as error:
            result["status"] = "saved-pending-native"
            result["error"] = str(error)
    result["observed"] = observed
    save_settings_result(state, result)
    return result


def apply_changes(changes, plugin_link, data, state, expected_revision, verify=None, on_backup=None,
                  confirm=None, reload=None, locked=False):
    check_hyprland()
    state_dir = state / "paperland"
    state_dir.mkdir(parents=True, exist_ok=True)
    # A Settings Apply keeps one lock hold across admission, receipts, and writes;
    # flock on a second descriptor in this process would conflict with its own.
    lock = nullcontext() if locked else setup_lock(state_dir)
    # Hyprland loads only the generated include chain: expected_revision exists
    # exactly when a loadable generated file changed, and confirm re-verifies
    # native state after a reload. Uninstall detaches a loaded include and asks
    # for a reload explicitly. Preference and Bar saves touch files it never reads.
    if reload is None:
        reload = expected_revision is not None or confirm is not None
    with lock:
        if verify:
            verify()
        for path, (before, _) in changes.items():
            if regular(path) != before:
                raise SetupError(f"Config changed after preview: {path}; rerun setup")
        if plugin_link and os.path.lexists(plugin_link):
            raise SetupError(f"Plugin path changed after preview: {plugin_link}")
        backup = Path(tempfile.mkdtemp(prefix="setup-backup-", dir=state_dir))
        modes = {}
        for index, (path, (before, _)) in enumerate(changes.items()):
            modes[path] = path.stat().st_mode & 0o777 if before is not None else 0o600
            if before is not None:
                (backup / str(index)).write_bytes(before)
        (backup / "files.json").write_text(json.dumps({str(i): {"path": str(p), "existed": c[0] is not None, "mode": modes[p]} for i, (p, c) in enumerate(changes.items())}, indent=2))
        if on_backup:
            on_backup(backup)
        written = []
        linked = False
        try:
            for path, (_, after) in changes.items():
                if after is None:
                    path.unlink()
                else:
                    atomic_write(path, after, modes[path])
                written.append(path)
            if plugin_link:
                plugin_link.parent.mkdir(parents=True, exist_ok=True)
                plugin_link.symlink_to(data / "paperland/plugin", target_is_directory=True)
                linked = True
            if reload:
                run(["hyprctl", "reload"])
                check_hyprland()
            if expected_revision is not None:
                if run(["hyprctl", "repl", "return _G.paperland_setup_revision"]) != expected_revision:
                    raise SetupError("Hyprland did not load the generated include; check which config is active")
        except BaseException as error:
            unrestored = []
            for path in reversed(written):
                before, after = changes[path]
                try:
                    if regular(path) != after:
                        raise SetupError("concurrent edit")
                    if before is None:
                        path.unlink()
                    else:
                        atomic_write(path, before, modes[path])
                except (OSError, SetupError) as failure:
                    unrestored.append(f"{path}: {failure}")
            if linked:
                if plugin_link.is_symlink() and os.readlink(plugin_link) == str(data / "paperland/plugin"):
                    plugin_link.unlink()
                else:
                    unrestored.append(f"{plugin_link}: concurrent edit")
            try:
                if reload:
                    run(["hyprctl", "reload"])
                    check_hyprland()
            except SetupError as recovery:
                unrestored.append(str(recovery))
            if unrestored:
                raise SetupError(f"Recovery incomplete: {'; '.join(unrestored)}; backup: {backup}; original failure: {error}") from error
            raise SetupError(f"Changes failed and were rolled back: {error}; backup: {backup}") from error
        # Native direction failure must keep the successfully saved choice.
        if confirm:
            confirm()
    print(f"Applied and validated. Backup: {backup}")
    return backup


def active_desktop_directions():
    output = run(["hyprctl", "repl", "return _G.paperland_monitor_direction_snapshot and "
                  "_G.paperland_monitor_direction_snapshot() or 'null'"])
    try:
        snapshot = json.loads(output)
        if snapshot is None:
            return None, False, {}
        available = snapshot["native_direction_available"]
        if not isinstance(available, bool):
            raise ValueError("invalid native Desktop direction capability")
        desktops = snapshot["desktops"]
        registered = snapshot["registered_desktops"]
        if not isinstance(desktops, dict) or any(not re.fullmatch(r"[1-9][0-9]*", number)
                or direction not in ("right", "left", "up", "down") for number, direction in desktops.items()):
            raise ValueError("invalid active Desktop directions")
        if not isinstance(registered, dict) or any(not re.fullmatch(r"[1-9][0-9]*", number)
                or enabled is not True for number, enabled in registered.items()):
            raise ValueError("invalid registered Desktop directions")
        if not available and desktops:
            raise ValueError("unverified active Desktop directions")
        if any(number not in registered for number in desktops):
            raise ValueError("unregistered active Desktop direction")
        return (desktops if available else None), available, registered
    except (ValueError, TypeError, KeyError) as error:
        raise SetupError("Cannot verify native Desktop direction ownership; leave the active rule unchanged") from error


def confirm_desktop_choices(choices):
    try:
        active, available, registered = active_desktop_directions()
        if available and all(number in registered and (number not in active or active[number] == value)
                             for number, value in choices.items()):
            return
    except SetupError:
        pass
    raise NativeDirectionPending("Desktop choice saved; native direction is unconfirmed or differs. Review and retry native application.")


def refuse_unsafe_retirement(previous_enabled, before_choices, after_choices, enabled):
    if not previous_enabled or not before_choices or (enabled and all(number in after_choices for number in before_choices)):
        return
    active, available, registered = active_desktop_directions()
    if active is None or not available:
        raise SetupError("Cannot verify native Desktop direction ownership; leave the active rule unchanged")
    retiring = set(before_choices) - set(after_choices) if enabled else set(registered)
    if retiring & set(registered):
        raise SetupError("Cannot safely remove an active numbered Desktop direction: Hyprland shares "
                         "identical-selector rule handles with foreign rules. The saved choice and live rule remain unchanged")


def run_setup(args, activate_default=False):
    _, _, _, state = paths()
    validate_settings_attempt(args.settings_attempt)
    if args.settings_attempt is not None and not args.settings_apply:
        raise SetupError("--settings-attempt requires --settings-apply or --settings-status")
    if not args.settings_apply:
        return _run_setup(args, activate_default)
    args.settings_attempt = args.settings_attempt or uuid.uuid4().hex
    # Only a proven pre-admission rejection may publish a refusal. Errors after
    # admission retain the prepared writer's failed/unknown recovery semantics.
    admitted = False
    try:
        with setup_lock(state / "paperland",
                        "Another Paperland Settings Apply owns the setup lock; "
                        "inspect it with setup --settings-status before retrying"):
            shared = regular(settings_result_path(state))
            prior = json.loads(shared) if shared is not None else {"status": "none"}
            if prior.get("attempt_id") == args.settings_attempt or regular(settings_refusal_path(state, args.settings_attempt)) is not None:
                raise SetupError("Settings attempt ID was already used; start a fresh consent")
            if prior["status"] != "unknown":
                prior = settings_status(state, locked=True)
            if prior["status"] in ("running", "unknown"):
                error = SetupError("Previous Settings Apply is unresolved; inspect its status before retry")
                save_settings_refusal(state, args.settings_attempt, error)
                raise error
            result = {"status": "running", "phase": "planning", "attempt_id": args.settings_attempt,
                      "pid": os.getpid(), "pid_start": process_start(os.getpid()),
                      "token": args.settings_apply, "files": {}, "manual": None,
                      "expected_revision": None, "native_choices": {}, "plugin_link": None}
            save_settings_result(state, result)
            admitted = True
            try:
                return _run_setup(args, activate_default)
            except BaseException as error:
                current = json.loads(regular(settings_result_path(state)))
                if current.get("phase") == "planning":
                    current["status"] = "failed"
                    current["error"] = str(error)
                    save_settings_result(state, current)
                raise
    except SetupBusy as error:
        if not admitted:
            save_settings_refusal(state, args.settings_attempt, error)
        raise


def _run_setup(args, activate_default=False):
    _, config, data, state = paths()
    interactive = not activate_default and not any((args.apply, args.dry_run, args.print_config,
        args.settings_preview, args.settings_apply, args.shortcut != "keep", args.resize != "keep",
        args.autostart != "keep", args.centering != "keep", args.strip_chord != "keep",
        args.bar_panels != "keep", args.omarchy_bar != "keep", args.omarchy_bar_scratchpad != "keep",
        args.monitor_direction != "keep",
        args.monitor_direction_override, args.desktop_direction, args.runtime_preferences, args.minimap_blur != "keep"))
    if interactive:
        if not sys.stdin.isatty() or not sys.stdout.isatty():
            raise SetupError("Interactive setup needs a terminal. Use explicit options with --dry-run or --apply; see setup --help.")
        wizard(args)
    launcher = data / "paperland/paperland"
    marker = data / "paperland/.installed-by-paperland"
    if not launcher.is_file() or not marker.is_file() or marker.read_text() != INSTALL_MARKER:
        raise SetupError("Run paperland install --no-setup first")
    owned = config / OWNED
    legacy = config / LEGACY
    names = str(config / NAMES)
    desktop_path = config / DESKTOP_DIRECTIONS
    main = config / "hypr/hyprland.lua"
    before_owned = regular(owned)
    before_legacy = regular(legacy)
    before_desktop, saved_desktops = read_desktop_record(desktop_path)
    desktop_choices = dict(saved_desktops)
    options = {"shortcut": "none", "resize": "system", "autostart": "off", "launcher": str(launcher)}
    previous = None
    # A recognized legacy file is migrated: its choices carry over and it is retired.
    for path, before, loads_names in ((legacy, before_legacy, None), (owned, before_owned, names)):
        if before is not None:
            try:
                previous = generated_options(before, loads_names)
            except (ValueError, KeyError, IndexError, TypeError, SetupError):
                raise SetupError(f"Refusing to overwrite edited or unowned config: {path}")
    if previous is not None:
        options.update(previous)
        options["launcher"] = str(launcher)
    previous_options = options.copy()
    if args.minimap_blur != "keep":
        options["minimap_blur"] = args.minimap_blur == "on"
    if options.get("desktop_direction_record", str(desktop_path)) != str(desktop_path):
        raise SetupError(f"Generated Desktop direction record path is not owned by Paperland: {owned}")
    if activate_default and "monitor_direction" not in options:
        options["monitor_direction"] = True
    if args.monitor_direction != "keep":
        options["monitor_direction"] = args.monitor_direction == "on"
    for item in args.desktop_direction:
        number, separator, value = item.partition("=")
        if (not separator or not re.fullmatch(r"[1-9][0-9]*", number) or len(number) > 10
                or int(number) > 2147483647 or value not in ("auto", "right", "down")):
            raise SetupError("Use --desktop-direction NUMBER=auto|right|down")
        if value == "auto":
            desktop_choices.pop(number, None)
        else:
            desktop_choices[number] = value
    if desktop_choices != saved_desktops:
        options["desktop_direction_record"] = str(desktop_path)
    refuse_unsafe_retirement(previous_options.get("monitor_direction"), saved_desktops,
                             desktop_choices, options.get("monitor_direction"))
    overrides = dict(options.get("monitor_direction_overrides", {}))
    for item in args.monitor_direction_override:
        name, separator, value = item.partition("=")
        if not separator or not re.fullmatch(r"[A-Za-z0-9_.:-]+", name) or value not in ("right", "left", "up", "down", "auto"):
            raise SetupError("Use --monitor-direction-override OUTPUT=right|left|up|down|auto")
        if value == "auto":
            overrides.pop(name, None)
        else:
            overrides[name] = value
    if overrides:
        options["monitor_direction_overrides"] = overrides
    else:
        options.pop("monitor_direction_overrides", None)
    for name in ("shortcut", "resize", "autostart", "centering"):
        value = getattr(args, name)
        if value != "keep":
            options[name] = shortcut(value) if name in ("shortcut", "centering") else value
    if args.strip_chord != "keep":
        if args.strip_chord == "none":
            options.pop("strip_chord", None)
            options.pop("bar_panels", None)
        else:
            options["strip_chord"] = args.strip_chord
    if args.bar_panels != "keep":
        options["bar_panels"] = args.bar_panels
    # Retained chords were saved before canonicalization existed; normalize them
    # too, or a saved code:021 slips past the spelling-based conflict checks.
    for name in ("shortcut", "centering"):
        if name in options:
            options[name] = shortcut(options[name])
    # Absence, not a stored "none": a config that declines this action must render
    # byte-identical to one written before the option existed.
    if options.get("centering") == "none":
        options.pop("centering")
    strip_chord = options.get("strip_chord")
    if strip_chord not in (None, STRIP_CHORD):
        raise SetupError("Invalid saved strip focus chord; rerun setup with --strip-chord none")
    if strip_chord is None:
        options.pop("bar_panels", None)
    elif options.get("bar_panels") not in ("relocate", "drop"):
        raise SetupError("Choose --bar-panels relocate or drop when enabling the strip chord")
    if args.bar_panels != "keep" and strip_chord is None:
        raise SetupError("--bar-panels requires the SUPER + CTRL strip chord")
    resize_keys = r"SUPER(?: \+ ALT| \+ CTRL)? \+ (?:MINUS|EQUAL|code:20|code:21)"
    if options["resize"] != "system" and re.fullmatch(resize_keys, options["shortcut"]):
        raise SetupError("The minimap shortcut conflicts with the selected resize shortcuts")
    centering_key = options.get("centering", "none")
    if centering_key != "none":
        if centering_key == options["shortcut"]:
            raise SetupError("The centering shortcut conflicts with the minimap shortcut")
        if options["resize"] != "system" and re.fullmatch(resize_keys, centering_key):
            raise SetupError("The centering shortcut conflicts with the selected resize shortcuts")
    if strip_chord == STRIP_CHORD:
        for name, chord in (("minimap", options["shortcut"]), ("centering", centering_key)):
            if shortcut_uses_digit_range(chord, ["SUPER", "CTRL"]):
                raise SetupError(f"Strip focus chord conflicts with the {name} shortcut: {chord}")
    if strip_chord == STRIP_CHORD and options["bar_panels"] == "relocate":
        for name, chord in (("minimap", options["shortcut"]), ("centering", centering_key)):
            if shortcut_uses_digit_range(chord, ["SUPER", "CTRL", "ALT"]):
                raise SetupError(f"Bar panel relocation conflicts with retained {name} shortcut: {chord}")
    if args.omarchy_bar == "enable":
        options["preview_control"] = True
    # Recorded, not recomputed in render(): see module_hashes().
    recorded_modules = previous_options.get("modules", {})
    current_modules = module_hashes(options, launcher)
    if current_modules:
        options["modules"] = current_modules
    else:
        options.pop("modules", None)
    bar_panels = options.get("bar_panels")
    if bar_panels is None:
        bar_panels = "restored" if previous_options.get("strip_chord") == STRIP_CHORD else "Omarchy default"
    changed_modules = sorted(name for name, digest in current_modules.items()
                             if name in recorded_modules and recorded_modules[name] != digest)
    generated = render(options, names).encode()
    if args.print_config:
        if args.omarchy_bar != "keep" or args.omarchy_bar_scratchpad != "keep":
            raise SetupError("--print-config exports Lua only; use --dry-run to preview Omarchy Bar changes")
        print(generated.decode(), end="")
        return
    changes = {}
    if args.runtime_preferences is not None:
        if not (args.settings_preview or args.settings_apply):
            raise SetupError("Runtime preference edits require the checked Settings saving flow")
        runtime_path = state / "paperland/settings.ini"
        before_runtime = regular(runtime_path)
        changes[runtime_path] = (before_runtime, runtime_change(before_runtime, args.runtime_preferences, args.runtime_baseline))
    if desktop_choices != saved_desktops:
        changes[desktop_path] = (before_desktop, desktop_record(desktop_choices))
    include_added = False
    manual = None
    manual_include = False
    bar_manual = None
    if (previous is not None or options["shortcut"] != "none" or options["resize"] != "system"
            or options["autostart"] != "off" or options.get("preview_control", False)
            or options.get("centering", "none") != "none" or strip_chord == STRIP_CHORD
            or "monitor_direction" in options or "minimap_blur" in options):
        # A tracked symlink is safe to inspect when its marked include is already present.
        before_main = main.read_bytes() if main.is_file() else None
        if before_main is None:
            raise SetupError(f"Expected a Lua config at {main}; use --print-config for manual integration")
        original = before_main.decode()
        include = BEGIN + f"dofile({lua(str(owned))})\n" + END
        if original.count(BEGIN) != original.count(END) or original.count(BEGIN) > 1:
            raise SetupError(f"Invalid Paperland include markers in {main}")
        if BEGIN in original:
            start, end = original.index(BEGIN), original.index(END) + len(END)
            if original[start:end] not in (include, BEGIN + f"dofile({lua(str(legacy))})\n" + END):
                raise SetupError(f"Paperland include was edited in {main}; review it manually")
            updated_main = original[:start] + include + original[end:]
            edit = "Replace the Paperland block in its tracked target with these exact lines"
        else:
            updated_main = original + ("" if original.endswith("\n") else "\n") + "\n" + include
            edit = "Add these exact lines to its tracked target"
        include_added = BEGIN not in original
        # paperland.lua loads the names file; a standalone include would load it twice.
        own_names = {f"dofile({lua(names)})"}
        if Path(names) == Path.home() / ".config" / NAMES:
            own_names.add(f'dofile(os.getenv("HOME") .. {lua("/.config/" + NAMES)})')
        leftovers = [(number, line.strip()) for number, line in enumerate(original.splitlines(), 1)
                     if NAMES.split("/")[-1] in line and not line.lstrip().startswith("--")]
        symlinked = any(part.is_symlink() for part in [main, *main.parents])
        removals = "".join(f"\nRemove {main}:{number}: {text}" for number, text in leftovers)
        if symlinked and updated_main != original:
            manual_include = True
            # Setup never edits through a dotfile symlink. It stages paperland.lua through the
            # normal consent and locked apply, unloaded, so the block is valid once pasted.
            manual = (f"Symlinked main config needs a manual include.\n{edit}:\n{include}{removals}\n"
                      "Then rerun setup" + (f" to retire {legacy}." if before_legacy is not None else " to validate it."))
            changes[owned] = (before_owned, generated)
        elif leftovers and (symlinked or any(text not in own_names for _, text in leftovers)):
            raise SetupError(("Symlinked main config needs a manual edit." if symlinked
                              else "Main config loads workspace names outside paperland.lua.") + removals)
        else:
            updated_main = "".join(line for line in updated_main.splitlines(True) if line.strip() not in own_names)
            changes[owned] = (before_owned, generated)
            changes[main] = (before_main, updated_main.encode())
            if before_legacy is not None:
                changes[legacy] = (before_legacy, None)
    plugin_link = None
    if args.omarchy_bar != "keep" or args.omarchy_bar_scratchpad != "keep":
        path, before, after, plugin_link, bar_manual = bar_change(
            config, data, launcher, args.omarchy_bar, args.omarchy_bar_scratchpad)
        if before is not None or after is not None:
            changes[path] = (before, after)
        if bar_manual:
            manual = f"{manual}\n{bar_manual}" if manual else bar_manual
    changes = {path: change for path, change in changes.items() if change[0] != change[1]}
    warnings = []
    if options.get("monitor_direction") is True:
        for path, line in direction_conflicts(main, (owned, legacy)):
            warning = f"Possible workspace direction rule at {path}:{line}; Paperland remains enabled."
            warnings.append(warning)
            if not args.settings_preview:
                print(f"Warning: {warning}", file=sys.stderr)
        if not previous_options.get("monitor_direction") and (args.apply or args.settings_apply or interactive):
            check_monitor_direction_capability()
    expected_revision = None
    if not manual_include and (owned in changes or main in changes or legacy in changes):
        expected_revision = re.search(r'_G.paperland_setup_revision = "([a-f0-9]+)"', generated.decode()).group(1)
    native_choices = {}
    if not manual_include and options.get("monitor_direction"):
        requested_desktops = {item.partition("=")[0] for item in args.desktop_direction}
        native_choices = desktop_choices if args.monitor_direction == "on" or not previous_options.get("monitor_direction") else {
            number: value for number, value in desktop_choices.items() if number in requested_desktops}
    retry_native = bool(args.desktop_direction and native_choices)
    def verify_native():
        if native_choices:
            confirm_desktop_choices(native_choices)

    def verify_retirement():
        refuse_unsafe_retirement(previous_options.get("monitor_direction"), saved_desktops,
                                 desktop_choices, options.get("monitor_direction"))

    if args.settings_preview or args.settings_apply:
        plan, dependencies = settings_plan(args, changes, plugin_link, config, data, launcher,
                                            options, warnings, manual, expected_revision, desktop_choices, retry_native)
        if args.settings_preview:
            print(json.dumps(plan))
            return
        if plan["token"] != args.settings_apply:
            raise SetupError("Reviewed Settings plan is stale; review the current file changes again")
        # run_setup owns admission and keeps the lock through the terminal receipt.
        result = {"status": "running", "attempt_id": args.settings_attempt,
                  "pid": os.getpid(), "pid_start": process_start(os.getpid()),
                  "token": plan["token"], "manual": manual, "manual_bar": bool(bar_manual),
                  "staged": plan["staged"],
                  "next_action": plan["next_action"],
                  "needs_rescan": args.omarchy_bar != "keep" or args.omarchy_bar_scratchpad != "keep",
                  "expected_revision": expected_revision,
                  "native_choices": native_choices,
                  "plugin_link": str(plugin_link) if plugin_link else None,
                  "files": {str(path): {"before": None if before is None else hashlib.sha256(before).hexdigest(),
                                        "after": None if after is None else hashlib.sha256(after).hexdigest()}
                            for path, (before, after) in changes.items()}}
        save_settings_result(state, result)
        try:
            if changes or plugin_link or retry_native:
                def verify():
                    if settings_dependencies(config, data, launcher) != dependencies:
                        raise SetupError("Reviewed Settings dependencies changed; review again")
                    verify_retirement()
                def on_backup(path):
                    result["backup"] = str(path)
                    save_settings_result(state, result)
                # confirm reloads for native verification only; a save with no
                # native work must not force one (see apply_changes).
                apply_changes(changes, plugin_link, data, state, expected_revision, verify, on_backup,
                              verify_native if native_choices else None, locked=True)
            result["status"] = ("saved-needs-manual" if manual else
                                 "saved-needs-rescan" if result["needs_rescan"] else "applied")
            save_settings_result(state, result)
        except NativeDirectionPending as error:
            result["status"] = "saved-pending-native"
            result["error"] = str(error)
            save_settings_result(state, result)
            raise
        except BaseException as error:
            result["status"] = "unknown" if not isinstance(error, SetupError) or "Recovery incomplete" in str(error) else "failed"
            result["error"] = str(error)
            save_settings_result(state, result)
            raise
        return
    if not changes and not plugin_link and not retry_native:
        if manual:
            raise SetupError(manual)
        print("Already configured; no files changed." if previous is not None or args.omarchy_bar != "keep"
              else "No configuration changes selected.")
        return
    print(f"Minimap shortcut: {options['shortcut']}\nResizing: {options['resize']}\nStart at login: {options['autostart']}\n"
          f"Centering toggle: {options.get('centering', 'none')}\n"
          f"Strip focus chord: {strip_chord or 'none'}\n"
          f"Bar panel shortcuts: {bar_panels}\nOmarchy bar: {args.omarchy_bar}\n"
          f"Monitor direction: {'on' if options.get('monitor_direction') else 'off'}")
    if strip_chord == STRIP_CHORD:
        for digit in range(1, 10):
            code = digit + 9
            original = f"SUPER + CTRL + code:{code}"
            if options["bar_panels"] == "relocate":
                destination = f"SUPER + CTRL + ALT + code:{code}"
                print(f"  Replace {original} with {destination}: {BAR_PANEL_COMMAND}{digit}")
            else:
                print(f"  Remove {original}: Bar panel {digit}")
    if changed_modules:
        print("Updated since this config was written, so these actions may behave differently:")
        for name in changed_modules:
            print(f"  {MODULES[name]}")
    print("Files to change:")
    for path in changes:
        print(f"  {path}")
    if plugin_link:
        print(f"  {plugin_link} -> {data / 'paperland/plugin'}")
    if options["resize"] != "system":
        print("Resize keys: Super + Minus/Equal (code:20/21), also with Alt or Ctrl.")
    inventory(options)
    # A copyable include is valid only after its target has been staged.
    manual_preview = STAGE_FIRST if manual_include and before_owned is None else manual
    if args.dry_run:
        show_diff(changes)
        print("Preview only; no files changed.")
        if manual:
            raise SetupError(manual_preview)
        return
    if interactive and (args.omarchy_bar != "keep" or args.omarchy_bar_scratchpad != "keep"):
        print("Exact Omarchy Bar changes to review:")
        show_diff(changes)
    if interactive:
        while True:
            decision = choose("Apply reviewed changes, including replacement of selected bindings?", ["Cancel", "Show file diff", "Print config to copy", "Apply changes"])
            if decision == "Show file diff":
                show_diff(changes)
            elif decision == "Print config to copy":
                print(generated.decode(), end="")
                return
            elif decision == "Cancel":
                print("Cancelled; no files changed.")
                return
            else:
                break
    elif not args.apply:
        show_diff(changes)
        print("Preview only. Add --apply to make these changes.")
        if manual:
            raise SetupError(manual_preview)
        return
    restoring_include = include_added
    replacing_bindings = (
        (options["shortcut"] != "none" and
         (restoring_include or options["shortcut"] != previous_options["shortcut"] or
          (previous is not None and previous.get("launcher") != str(launcher))))
        or (options["resize"] != "system" and
            (restoring_include or options["resize"] != previous_options["resize"]))
        or (options.get("centering", "none") != "none" and
            (restoring_include or options.get("centering") != previous_options.get("centering")))
        or (strip_chord == STRIP_CHORD and
            (restoring_include or previous_options.get("strip_chord") != STRIP_CHORD or
             options.get("bar_panels") != previous_options.get("bar_panels")))
    )
    if not interactive and replacing_bindings and not args.replace_bindings:
        raise SetupError("Binding changes require --replace-bindings after reviewing the preview")
    apply_changes(changes, plugin_link, data, state, expected_revision,
                  verify=verify_retirement, confirm=verify_native if native_choices else None)
    if args.omarchy_bar != "keep" or args.omarchy_bar_scratchpad != "keep":
        print("Configuration saved; Paperland may not be active until Omarchy loads it. Run: omarchy-shell shell "
              + ("rescanPlugins" if plugin_link else "reloadConfig"))
    if manual:
        raise SetupError(f"{STAGE_FIRST}\n{manual}")


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    actions = result.add_subparsers(dest="action", required=True)
    installation = actions.add_parser("install", help="Install to XDG_DATA_HOME and ~/.local/bin; offer setup in a terminal")
    installation.add_argument("--no-setup", action="store_true", help="Install files without interactive setup or desktop changes")
    actions.add_parser("uninstall", help="Detach owned desktop integration and retain runtime files for review")
    setup = actions.add_parser("setup", help="Review optional desktop configuration; use no options for the wizard")
    setup.add_argument("--shortcut", default="keep", help="keep, none, or a chord such as 'SUPER + M'")
    setup.add_argument("--resize", choices=["keep", "system", "incremental", "presets"], default="keep")
    setup.add_argument("--autostart", choices=["keep", "on", "off"], default="keep")
    setup.add_argument("--centering", default="keep", help="keep, none, or a chord that toggles centered/packed columns")
    setup.add_argument("--strip-chord", choices=["keep", "none", STRIP_CHORD], default="keep",
                       help="keep, none, or the fixed SUPER + CTRL numbered strip focus chord")
    setup.add_argument("--bar-panels", choices=["keep", "relocate", "drop"], default="keep",
                       help="keep, relocate, or drop Omarchy Bar panel shortcuts when enabling strip focus")
    setup.add_argument("--omarchy-bar", choices=["keep", "enable", "disable"], default="keep")
    setup.add_argument("--omarchy-bar-scratchpad", choices=["keep", "show", "hide"], default="keep",
                       help="Show or hide Paperland's Omarchy Bar Scratchpad pill")
    setup.add_argument("--runtime-preferences", help="Validated runtime preference edits as JSON")
    setup.add_argument("--runtime-baseline", help="Runtime values observed before editing as JSON")
    setup.add_argument("--minimap-blur", choices=["keep", "on", "off"], default="keep")
    setup.add_argument("--monitor-direction", choices=["keep", "on", "off"], default="keep")
    setup.add_argument("--monitor-direction-override", action="append", default=[], metavar="OUTPUT=DIRECTION")
    setup.add_argument("--desktop-direction", action="append", default=[], metavar="NUMBER=auto|right|down")
    mode = setup.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="Show changes without writing files")
    mode.add_argument("--print-config", action="store_true", help="Print the generated Lua for manual integration")
    mode.add_argument("--apply", action="store_true", help="Apply explicit selections after preview")
    mode.add_argument("--settings-preview", action="store_true", help="Print checked Settings plan as JSON")
    mode.add_argument("--settings-apply", metavar="TOKEN", help="Apply only the matching reviewed Settings plan")
    setup.add_argument("--settings-attempt", metavar="ID",
                       help="Attempt ID for --settings-apply or --settings-status: 16-64 lowercase hex; a fresh one is generated when omitted")
    mode.add_argument("--settings-status", action="store_true", help="Query the last Settings Apply result as JSON")
    setup.add_argument("--replace-bindings", action="store_true", help="Allow replacement of the selected shortcuts with --apply")
    return result


if __name__ == "__main__":
    try:
        arguments = parser().parse_args()
        if arguments.action == "install":
            install(arguments.no_setup)
        elif arguments.action == "uninstall":
            uninstall()
        elif arguments.settings_status:
            print(json.dumps(settings_status(paths()[3], attempt=arguments.settings_attempt)))
        else:
            run_setup(arguments)
    except (SetupError, OSError, EOFError, KeyboardInterrupt, UnicodeError) as failure:
        print(f"paperland: {str(failure) or 'Cancelled'}", file=sys.stderr)
        sys.exit(1)
