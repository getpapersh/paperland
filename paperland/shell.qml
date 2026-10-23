import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "Layout.js" as Layout
import "SettingsRegistry.js" as Registry
import "SettingsIni.js" as Ini
import "native" as Native

ShellRoot {
  id: root
  // Live values. Changes persist through SettingsFile's writer (root.persist); the file's contents
  // flow back in through applyFile, so every writer's change reaches these properties.
  QtObject {
    id: settings
    property bool pinned: Registry.KEYS.pinned.default
    property bool peek: Registry.KEYS.peek.default
    property int peekSeconds: Registry.KEYS.peekSeconds.default
    property string minimapOpacityMode: Registry.KEYS.minimapOpacityMode.default
    property int minimapBackgroundOpacity: Registry.KEYS.minimapBackgroundOpacity.default
    property int minimapEntireOpacity: Registry.KEYS.minimapEntireOpacity.default
    // Overview window list docked open by default; typing reveals it when off.
    property bool overviewWindowList: Registry.KEYS.overviewWindowList.default
    property int overviewDensity: Registry.KEYS.overviewDensity.default
    // A saved false is indistinguishable from an absent key, so record the
    // upgrade instead of guessing on every start. 0 means pre-Peek state.
    property int settingsVersion: 0
    property int autoHideSeconds: 0
    property var workspaceDirections: ({})
    // Whether an open scratchpad replaces the desktop on its display's strip.
    property bool scratchpadFollow: Registry.KEYS.scratchpadFollow.default
    // PaperMac's "Show Desktop number on switch", on by default.
    property bool switchOverlay: Registry.KEYS.switchOverlay.default
    // Alt+Tab search matching, as in PaperMac: "fuzzy" (default) or "exact".
    property string switcherSearchMode: Registry.KEYS.switcherSearchMode.default
    // Alt+Tab card size preset (small, medium, large, xl) and mirroring onto every display.
    property string switcherSize: Registry.KEYS.switcherSize.default
    property bool switcherOnAllDisplays: Registry.KEYS.switcherOnAllDisplays.default
    // Set once the first-run welcome is closed by any route.
    property bool welcomeShown: false
    // Empty until the first start records the running version (fresh install).
    property string whatsNewLastSeenVersion: ""
  }
  SettingsFile {
    id: file
    path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/paperland/settings.ini"
    writer: Quickshell.shellPath("shared/settings_ini.py")
    onChanged: text => root.applyFile(text)
  }
  readonly property string switcherSearchMode: Registry.KEYS.switcherSearchMode.values.indexOf(settings.switcherSearchMode) >= 0 ? settings.switcherSearchMode : Registry.KEYS.switcherSearchMode.default
  readonly property string switcherSize: Registry.KEYS.switcherSize.values.indexOf(settings.switcherSize) >= 0 ? settings.switcherSize : Registry.KEYS.switcherSize.default
  readonly property int peekSeconds: Math.max(1, Math.min(60, settings.peekSeconds))
  readonly property string minimapOpacityMode: settings.minimapOpacityMode === "entire" ? "entire" : "background"
  readonly property int minimapBackgroundOpacity: Math.max(0, Math.min(100, settings.minimapBackgroundOpacity))
  readonly property int minimapEntireOpacity: Math.max(20, Math.min(100, settings.minimapEntireOpacity))
  readonly property int overviewDensity: settings.overviewDensity >= 0 && settings.overviewDensity <= 2 ? settings.overviewDensity : 0
  readonly property var service: Native.Runtime.service
  readonly property bool startupHidden: Quickshell.env("PAPERLAND_START_HIDDEN") === "1"
  Binding { target: root.service; property: "pinned"; value: settings.pinned }
  Component.onCompleted: {
    var saved = file.read();
    if (saved !== null) root.applyFile(saved);
    root.migrateSettings();
    root.pushFollowToLua();
    Native.Runtime.computeIdentity([Native.Runtime.runtimeDir]);
    // Native E2E harnesses start from empty state; the card would cover their fixtures.
    if (!settings.welcomeShown && Quickshell.env("PAPERLAND_E2E") !== "1") {
      onboarding.openWelcome();
      whatsNewPending = true;
    }
    // Its file readers start loading only once the whole tree has completed.
    Qt.callLater(root.releaseWhatsNew);
  }
  // Set only for the start that opened the card; one surface at a time, so the
  // notes wait for the card and then the coach, and replays never re-arm it.
  property bool whatsNewPending: false
  function releaseWhatsNew(): void {
    if (onboarding.welcomeOpen || onboarding.coachOpen) return;
    // Skipping leaves the saved version alone, so the notes show on the next start.
    var skip = whatsNewPending && whatsNewWindow.opened;
    whatsNewPending = false;
    if (!skip) showWhatsNew();
  }
  function showWhatsNew(): void {
    // Saved before dismissal so quitting with the window open never re-shows it.
    var seen = whatsNewWindow.showUnseen(settings.whatsNewLastSeenVersion);
    if (seen !== settings.whatsNewLastSeenVersion) {
      settings.whatsNewLastSeenVersion = seen;
      root.persist(["whatsNewLastSeenVersion"]);
    }
  }
  // The Lua module can finish initializing after this shell starts; each flip
  // of usingLua re-pushes so neither startup order can leave it stale.
  Connections {
    target: Hyprland
    function onUsingLuaChanged() { if (Hyprland.usingLua) root.pushFollowToLua(); }
  }
  // strip-focus.lua numbers whichever workspace this global selects: the open
  // scratchpad while true (or unset, Lua's documented default and the
  // preference default), the desktop workspace while false.
  function pushFollowToLua(): void {
    Hyprland.dispatch('function() _G.paperland_strip_follow = '
      + (settings.scratchpadFollow ? 'true' : 'false') + ' end');
  }
  function migrateSettings() {
    if (settings.settingsVersion < 1) {
      // Before Peek, an unpinned strip always revealed on navigation and hid
      // again after the saved delay. Keep those installs automatic.
      settings.peek = !settings.pinned;
      if (settings.autoHideSeconds >= 1 && settings.autoHideSeconds <= 60) settings.peekSeconds = settings.autoHideSeconds;
      settings.settingsVersion = 1;
      root.persist(["settingsVersion", "peek", "peekSeconds"]);
    } else if (settings.pinned && settings.peek) {
      settings.peek = false;
      root.persist(["peek"]);
    }
  }
  Binding { target: root.service; property: "workspaceDirections"; value: settings.workspaceDirections }
  Binding { target: overview; property: "windowListEnabled"; value: settings.overviewWindowList }
  Binding { target: overview; property: "density"; value: root.overviewDensity }
  Binding { target: root.service; property: "scratchpadFollow"; value: settings.scratchpadFollow }
  Connections {
    target: overview
    function onWindowListToggleRequested(value) {
      settings.overviewWindowList = value;
      root.persist(["overviewWindowList"]);
    }
    function onDensityChangeRequested(value) {
      settings.overviewDensity = value;
      root.persist(["overviewDensity"]);
    }
  }
  Connections {
    target: root.service
    // Pinning and Peek are the two automatic modes; turning one on ends the
    // other, and turning both off leaves the strip where the user put it.
    // Unpinning returns to Peek, so the strip stays automatic by default.
    function onPinRequested(value) {
      settings.pinned = value;
      settings.peek = !value;
      root.persist(["pinned", "peek"]);
    }
    function onFollowRequested(value) {
      settings.scratchpadFollow = value;
      root.persist(["scratchpadFollow"]);
      root.pushFollowToLua();
    }
  }
  Connections {
    target: Native.Runtime.sendMenu
    function onStarting() { switcher.suspendForMenu(); overview.pauseActivation(); }
    function onSubmittingChanged() { if (Native.Runtime.sendMenu.submitting) { switcher.abort(); overview.close(); } }
  }
  // Omarchy's optional palette file. The shared Theme singleton must stay pure
  // QtQuick for the plain-Qt component checks, so its FileView lives here and
  // feeds Theme.readSettingsPalette; SettingsWindow's refresh re-reads through
  // the singleton's signal.
  FileView {
    id: paletteFile
    path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: Theme.readSettingsPalette(text())
    onLoadFailed: Theme.systemPalette = ({})
  }
  Connections {
    target: Theme
    function onPaletteRefreshRequested() { paletteFile.reload(); }
  }
  WindowSwitcher {
    id: switcher
    service: root.service
    searchMode: root.switcherSearchMode
    sizePreset: root.switcherSize
    allDisplays: settings.switcherOnAllDisplays
    onStarting: { overview.close(); whatsNewWindow.close(); }
    onSizeRequested: function(preset) { root.setSwitcherSize(preset); }
  }
  Overview {
    id: overview
    suppressed: switcher.active
    service: root.service
    startupHidden: root.startupHidden
    peekSeconds: root.peekSeconds
    peekEnabled: settings.peek
    // Peek must not hide the minimap mid-lesson; the saved preference is untouched.
    coachHold: onboarding.coachOpen
    opacityMode: root.minimapOpacityMode
    backgroundOpacity: root.minimapBackgroundOpacity
    entireOpacity: root.minimapEntireOpacity
    onPeekSecondsRequested: function(seconds) { root.setPeekSeconds(seconds); }
    onPeekRequested: function(value) { root.setPeek(value); }
    onSettingsRequested: { switcher.abort(); overview.close(); settingsWindow.open(); }
    onWelcomeRequested: root.replayWelcome()
  }
  Onboarding {
    id: onboarding
    service: root.service
    minimapVisible: overview.visibleMinimaps > 0
    onWelcomeClosed: {
      settings.welcomeShown = true; root.persist(["welcomeShown"]);
      // Start Flowing opens the coach right after this signal; check afterwards.
      if (root.whatsNewPending) Qt.callLater(root.releaseWhatsNew);
    }
    onCoachOpenChanged: if (!coachOpen && root.whatsNewPending) Qt.callLater(root.releaseWhatsNew)
    onFlowStarted: overview.showMinimap()
    onMinimapShowRequested: overview.showMinimap()
  }
  function replayWelcome(): void {
    switcher.abort();
    overview.close();
    onboarding.openWelcome();
  }
  SettingsWindow {
    id: settingsWindow
    service: root.service
    savedPreferences: ({pinned: settings.pinned, peek: settings.peek, peekSeconds: root.peekSeconds,
      minimapOpacityMode: root.minimapOpacityMode, minimapBackgroundOpacity: root.minimapBackgroundOpacity,
      minimapEntireOpacity: root.minimapEntireOpacity, overviewWindowList: settings.overviewWindowList,
      overviewDensity: root.overviewDensity, scratchpadFollow: settings.scratchpadFollow,
      switchOverlay: settings.switchOverlay, switcherSearchMode: root.switcherSearchMode,
      switcherSize: root.switcherSize, switcherOnAllDisplays: settings.switcherOnAllDisplays})
    // The file watcher usually delivers a Save first; this rereads right away so the draft resets from saved values.
    onPreferencesReloadRequested: root.reloadSettings()
  }

  // Persists the named settings through the shared writer. The live value is already assigned.
  function persist(keys: var): void {
    var updates = {};
    for (var i = 0; i < keys.length; i++) {
      var value = settings[keys[i]];
      updates[keys[i]] = keys[i] === "workspaceDirections" ? JSON.stringify(value) : value;
    }
    file.write(updates);
  }
  // Applies settings.ini's text. A key with a write in flight keeps its newer live value; invalid
  // entries keep the live value and are reported.
  function applyFile(text: string): var {
    var saved = Ini.parse(text);
    var follow = settings.scratchpadFollow;
    var result = Registry.read(function(key, fallback) { return key in saved ? saved[key] : fallback; }, settings);
    var values = {};
    for (var key in result.values) if (!file.isPending(key)) values[key] = result.values[key];
    Registry.apply(settings, values);
    var internal = Registry.readInternal(function(key) { return saved[key]; });
    for (var name in internal) {
      if (file.isPending(name)) continue;
      var next = internal[name];
      if (name === "workspaceDirections") {
        if (JSON.stringify(next) !== JSON.stringify(settings.workspaceDirections)) settings.workspaceDirections = next;
      } else settings[name] = next;
    }
    if (settings.scratchpadFollow !== follow) root.pushFollowToLua();
    root.lastRead = result;
    return result;
  }
  property var lastRead: ({ values: {}, errors: [] })
  // Rereads settings.ini now; the file watcher normally has already delivered it.
  function reloadSettings(): var {
    file.refresh();
    return root.lastRead;
  }
  function setPeek(value) {
    if (value && settings.pinned) root.service.setPinned(false);
    settings.peek = value;
    root.persist(["peek"]);
    return true;
  }
  function setSwitcherSize(preset: string): bool {
    if (Registry.KEYS.switcherSize.values.indexOf(preset) < 0) return false;
    settings.switcherSize = preset;
    root.persist(["switcherSize"]);
    return true;
  }
  function setPeekSeconds(seconds) {
    if (!Number.isInteger(seconds) || seconds < 1 || seconds > 60) return false;
    settings.peekSeconds = seconds;
    root.persist(["peekSeconds"]);
    return true;
  }
  function setMinimapOpacityMode(mode: string): bool {
    if (mode !== "background" && mode !== "entire") return false;
    settings.minimapOpacityMode = mode;
    root.persist(["minimapOpacityMode"]);
    return true;
  }
  function setMinimapOpacityValue(value: int): bool {
    var minimum = root.minimapOpacityMode === "entire" ? 20 : 0;
    if (!Number.isInteger(value) || value < minimum || value > 100) return false;
    var key = root.minimapOpacityMode === "entire" ? "minimapEntireOpacity" : "minimapBackgroundOpacity";
    settings[key] = value;
    root.persist([key]);
    return true;
  }
  ActivationNotice { service: root.service; noticeScreen: Hyprland.focusedMonitor ? Quickshell.screens.find(function(screen) { return screen.name === Hyprland.focusedMonitor.name; }) || null : null }
  WorkspaceNames { id: workspaceNames }
  WorkspaceSwitchCard { id: switchCards; showCards: settings.switchOverlay }
  WhatsNew { id: whatsNewWindow }
  // Navigation surfaces take over from the notes rather than sharing the display with them.
  Connections {
    target: overview
    function onOpenedChanged() { if (overview.opened) whatsNewWindow.close(); }
  }
  Connections {
    target: settingsWindow
    function onOpenedChanged() { if (settingsWindow.opened) whatsNewWindow.close(); }
  }
  IpcHandler {
    target: "paperlandNames"
    function ready(): bool { return workspaceNames.ready && Object.keys(root.service.catalog.entries).length > 0; }
    function begin(workspace: int): string { return workspaceNames.begin(workspace); }
    function submit(payload: string): string { return workspaceNames.submit(payload); }
    function status(requestId: string): string { return workspaceNames.status(requestId); }
  }
  IpcHandler {
    target: "paperland"
    function show(): void { overview.showMinimap(); }
    function hide(): void { overview.hideMinimap(); }
    function toggle(): void { switcher.abort(); overview.toggleMinimap(); }
    function search(): void { switcher.abort(); overview.open(); }
    function settings(): void { switcher.abort(); settingsWindow.open(); }
    function welcome(): void { root.replayWelcome(); }
    function whatsNew(): bool { switcher.abort(); overview.close(); return whatsNewWindow.showHistory(); }
    // One command for peeking and how long it lasts: "on", "off" or 1-60 seconds.
    function peek(value: string): bool {
      if (value === "on" || value === "off") return root.setPeek(value === "on");
      return /^[0-9]+$/.test(value) && root.setPeekSeconds(Number(value));
    }
    function pin(value: bool): void { service.setPinned(value); }
    function switcherSize(value: string): bool { return root.setSwitcherSize(value); }
    function switcherAllDisplays(value: string): bool {
      if (value !== "on" && value !== "off") return false;
      settings.switcherOnAllDisplays = value === "on";
      root.persist(["switcherOnAllDisplays"]);
      return true;
    }
    function follow(value: string): bool {
      if (value !== "on" && value !== "off") return false;
      settings.scratchpadFollow = value === "on";
      root.persist(["scratchpadFollow"]);
      root.pushFollowToLua();
      return true;
    }
    function switchOverlay(value: string): bool {
      if (value !== "on" && value !== "off") return false;
      settings.switchOverlay = value === "on";
      root.persist(["switchOverlay"]);
      return true;
    }
    function direction(workspace: int, value: string): bool {
      if (!Layout.validDirection(value) && value !== "global") return false;
      var directions = Object.assign({}, settings.workspaceDirections);
      if (value === "global") delete directions[workspace];
      else directions[workspace] = value;
      settings.workspaceDirections = directions;
      root.persist(["workspaceDirections"]);
      return true;
    }
    // `paperland config set` and `unset` write the file; the shell follows it. Reload forces a reread.
    function configReload(): string {
      var result = root.reloadSettings();
      return JSON.stringify({ ok: true, values: result.values, errors: result.errors });
    }
    function stripBadges(payload: string): bool { return Native.Runtime.showStripBadges(payload); }
    function stripColumns(payload: string): bool { return Native.Runtime.showStripColumns(payload); }
    function quit(): void { Qt.quit(); }
    function requestStop(): bool {
      if (settingsWindow.stopBlocked) return false;
      // Return the decision over IPC before destroying its handler.
      Qt.callLater(function() { Qt.quit(); });
      return true;
    }
    function activate(address: string): void { overview.activate(address); }
    function pan(workspace: int, delta: real): bool {
      if (!service.canPan(workspace) || !isFinite(delta)) return false;
      service.pan(workspace, delta);
      return true;
    }
    function status(): string {
      return JSON.stringify({ switcherOpened: switcher.opened, switcherSelected: switcher.selected, switcherIds: switcher.ids, switcherPending: switcher.pendingTarget, activationError: service.activationError, opened: overview.opened, welcomeOpened: onboarding.welcomeOpen, coachLesson: onboarding.coachOpen ? onboarding.lesson.id : "", coachFeedback: onboarding.coach.feedback, coachWaiting: onboarding.cold.waiting, coachInstruction: onboarding.coachOpen ? onboarding.coachInstruction : "", workspaceActionsOpened: overview.workspaceActionsOpened, workspaceActionsMode: overview.workspaceActionsMode, workspaceActionsKeyboardReady: overview.workspaceActionsKeyboardReady, workspaceActionsFocus: overview.workspaceActionsFocus, minimapVisible: overview.visibleMinimaps > 0, visibleMinimaps: overview.visibleMinimaps, pinned: service.pinned, peek: settings.peek, peekSeconds: root.peekSeconds, minimapOpacityMode: root.minimapOpacityMode, minimapBackgroundOpacity: root.minimapBackgroundOpacity, minimapEntireOpacity: root.minimapEntireOpacity, scratchpadFollow: settings.scratchpadFollow, switchOverlay: settings.switchOverlay,
        overviewWindowList: settings.overviewWindowList, overviewDensity: root.overviewDensity,
        switcherSize: root.switcherSize, switcherSearchMode: root.switcherSearchMode, switcherOnAllDisplays: settings.switcherOnAllDisplays,
        query: overview.query, matches: overview.matchIds.length, selected: overview.selectedAddress,
        searchFocused: overview.searchFocused, scope: overview.scope,
        scopeMonitor: overview.scopeMonitor, scopeWorkspace: overview.scopeWorkspace,
        focused: service.focusedAddress, windows: Object.keys(service.windows).length,
        rows: service.rowIds.map(function(id) {
          var row = service.rows[id];
          return { workspace: id, monitor: row.monitor, active: row.active, vertical: row.vertical,
            // Per-row: only the row a strip actually displays reports visible
            // on a visible display, so inactive rows stay dark in status.
            minimapVisible: row.active && !overview.opened && !!overview.displayVisibility[row.monitor],
            canPan: service.canPan(id), windows: row.windows.length,
            direction: row.direction, directionSource: row.directionSource };
        }) });
    }
    // Read-only capture health. Slots self-report through their own bindings;
    // window text stays out unless the request explicitly asks for detail.
    function captures(detail: string): string {
      // The Alt+Tab switcher shows live thumbnails but does not self-report.
      return Native.Runtime.captureReport("standalone", detail === "detail", [{ surface: "switcher",
        reason: "The window switcher's thumbnails do not report capture state." }]);
    }
    function identity(): string { return Native.Runtime.identityReport(); }
    function diagnosticsBegin(): string { return Native.Runtime.beginDiagnostics(); }
    function diagnosticsStatus(request: string): string { return Native.Runtime.diagnosticsStatus(request); }
  }
}
