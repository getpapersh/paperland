import QtQuick
import QtCore
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "Layout.js" as Layout
import "SettingsRegistry.js" as Registry
import "native" as Native

ShellRoot {
  id: root
  Settings {
    id: settings
    location: "file://" + (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/paperland/settings.ini"
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
    property bool switchOverlay: true
    // Alt+Tab search matching, as in PaperMac: "fuzzy" (default) or "exact".
    property string switcherSearchMode: "fuzzy"
    // Alt+Tab card size preset (small, medium, large, xl) and mirroring onto every display.
    property string switcherSize: "large"
    property bool switcherOnAllDisplays: false
    // Set once the first-run welcome is closed by any route.
    property bool welcomeShown: false
    // Empty until the first start records the running version (fresh install).
    property string whatsNewLastSeenVersion: ""
  }
  readonly property string switcherSize: ["small", "medium", "large", "xl"].indexOf(settings.switcherSize) >= 0 ? settings.switcherSize : "large"
  readonly property int peekSeconds: Math.max(1, Math.min(60, settings.peekSeconds))
  readonly property string minimapOpacityMode: settings.minimapOpacityMode === "entire" ? "entire" : "background"
  readonly property int minimapBackgroundOpacity: Math.max(0, Math.min(100, settings.minimapBackgroundOpacity))
  readonly property int minimapEntireOpacity: Math.max(20, Math.min(100, settings.minimapEntireOpacity))
  readonly property int overviewDensity: settings.overviewDensity >= 0 && settings.overviewDensity <= 2 ? settings.overviewDensity : 0
  readonly property var service: Native.Runtime.service
  readonly property bool startupHidden: Quickshell.env("PAPERLAND_START_HIDDEN") === "1"
  Binding { target: root.service; property: "pinned"; value: settings.pinned }
  Component.onCompleted: {
    root.migrateSettings();
    root.pushFollowToLua();
    // Native E2E harnesses start from empty state; the card would cover their fixtures.
    if (!settings.welcomeShown && Quickshell.env("PAPERLAND_E2E") !== "1") onboarding.openWelcome();
    // Its file readers start loading only once the whole tree has completed.
    Qt.callLater(root.showWhatsNew);
  }
  function showWhatsNew(): void {
    // Saved before dismissal so quitting with the window open never re-shows it.
    var seen = whatsNewWindow.showUnseen(settings.whatsNewLastSeenVersion);
    if (seen !== settings.whatsNewLastSeenVersion) {
      settings.whatsNewLastSeenVersion = seen;
      settings.sync();
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
    } else if (settings.pinned && settings.peek) {
      settings.peek = false;
    } else return;
    settings.sync();
  }
  Binding { target: root.service; property: "workspaceDirections"; value: settings.workspaceDirections }
  Binding { target: overview; property: "windowListEnabled"; value: settings.overviewWindowList }
  Binding { target: overview; property: "density"; value: root.overviewDensity }
  Binding { target: root.service; property: "scratchpadFollow"; value: settings.scratchpadFollow }
  Connections {
    target: overview
    function onWindowListToggleRequested(value) {
      settings.overviewWindowList = value;
      settings.sync();
    }
    function onDensityChangeRequested(value) {
      settings.overviewDensity = value;
      settings.sync();
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
      settings.sync();
    }
    function onFollowRequested(value) {
      settings.scratchpadFollow = value;
      settings.sync();
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
    searchMode: settings.switcherSearchMode === "exact" ? "exact" : "fuzzy"
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
    onWelcomeClosed: { settings.welcomeShown = true; settings.sync(); }
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
      overviewDensity: root.overviewDensity, scratchpadFollow: settings.scratchpadFollow})
    // Qt Settings has no external change notifications; refresh its properties after the checked writer saves.
    onPreferencesReloadRequested: root.reloadSettings()
  }

  function applySettings(values: var): void {
    Registry.apply(settings, values);
    if ("scratchpadFollow" in values) root.pushFollowToLua();
  }
  function applyConfig(result: var): string {
    if (result.ok) root.applySettings(result.changes);
    return JSON.stringify(result);
  }
  // Rereads settings.ini; invalid entries keep the live value and are reported.
  function reloadSettings(): var {
    var result = Registry.reload(settings);
    root.pushFollowToLua();
    return result;
  }
  function setPeek(value) {
    if (value && settings.pinned) root.service.setPinned(false);
    settings.peek = value;
    settings.sync();
    return true;
  }
  function setSwitcherSize(preset: string): bool {
    if (["small", "medium", "large", "xl"].indexOf(preset) < 0) return false;
    settings.switcherSize = preset;
    settings.sync();
    return true;
  }
  function setPeekSeconds(seconds) {
    if (!Number.isInteger(seconds) || seconds < 1 || seconds > 60) return false;
    settings.peekSeconds = seconds;
    settings.sync();
    return true;
  }
  function setMinimapOpacityMode(mode: string): bool {
    if (mode !== "background" && mode !== "entire") return false;
    settings.minimapOpacityMode = mode;
    settings.sync();
    return true;
  }
  function setMinimapOpacityValue(value: int): bool {
    var minimum = root.minimapOpacityMode === "entire" ? 20 : 0;
    if (!Number.isInteger(value) || value < minimum || value > 100) return false;
    if (root.minimapOpacityMode === "entire") settings.minimapEntireOpacity = value;
    else settings.minimapBackgroundOpacity = value;
    settings.sync();
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
      settings.sync();
      return true;
    }
    function follow(value: string): bool {
      if (value !== "on" && value !== "off") return false;
      settings.scratchpadFollow = value === "on";
      settings.sync();
      root.pushFollowToLua();
      return true;
    }
    function switchOverlay(value: string): bool {
      if (value !== "on" && value !== "off") return false;
      settings.switchOverlay = value === "on";
      settings.sync();
      return true;
    }
    function direction(workspace: int, value: string): bool {
      if (!Layout.validDirection(value) && value !== "global") return false;
      var directions = Object.assign({}, settings.workspaceDirections);
      if (value === "global") delete directions[workspace];
      else directions[workspace] = value;
      settings.workspaceDirections = directions;
      settings.sync();
      return true;
    }
    // `paperland config`: replies are JSON so the CLI can report validation errors.
    function configList(): string { return JSON.stringify(Registry.snapshot(settings)); }
    function configSet(key: string, value: string): string { return root.applyConfig(Registry.resolve(key, value)); }
    function configUnset(key: string): string { return root.applyConfig(Registry.reset(key)); }
    function configReload(): string {
      var result = root.reloadSettings();
      return JSON.stringify({ ok: true, values: result.values, errors: result.errors });
    }
    function stripBadges(payload: string): bool { return Native.Runtime.showStripBadges(payload); }
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
      return JSON.stringify({ switcherOpened: switcher.opened, switcherSelected: switcher.selected, switcherIds: switcher.ids, switcherPending: switcher.pendingTarget, activationError: service.activationError, opened: overview.opened, welcomeOpened: onboarding.welcomeOpen, coachLesson: onboarding.coachOpen ? onboarding.lesson.id : "", coachFeedback: onboarding.coach.feedback, coachWaiting: onboarding.cold.waiting, coachInstruction: onboarding.coachOpen ? onboarding.coachInstruction : "", workspaceActionsOpened: overview.workspaceActionsOpened, minimapVisible: overview.visibleMinimaps > 0, visibleMinimaps: overview.visibleMinimaps, pinned: service.pinned, peek: settings.peek, peekSeconds: root.peekSeconds, minimapOpacityMode: root.minimapOpacityMode, minimapBackgroundOpacity: root.minimapBackgroundOpacity, minimapEntireOpacity: root.minimapEntireOpacity, scratchpadFollow: settings.scratchpadFollow, switchOverlay: settings.switchOverlay,
        overviewWindowList: settings.overviewWindowList, overviewDensity: root.overviewDensity,
        switcherSize: root.switcherSize, switcherOnAllDisplays: settings.switcherOnAllDisplays,
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
  }
}
