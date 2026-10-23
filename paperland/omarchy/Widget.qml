pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import "paperland/shared/PreviewGeometry.js" as PreviewGeometry
import "paperland/shared/PillColumn.js" as PillColumn
import "paperland/shared/StripColumns.js" as Pill
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import qs.Ui
import qs.Commons
import "paperland/native" as Native
import "paperland" as Paper
import "paperland/shared" as Shared

BarWidget {
  id: root
  moduleName: "json.paperland"
  readonly property var service: Native.Runtime.service
  readonly property var barTheme: root.bar
  readonly property string executable: setting("executable", "paperland")
  // Bar presentation values belong to this module's own shell.json entry;
  // every field is normalized here, before any typed QML assignment.
  readonly property var pillSettings: Pill.normalizePillSettings(function(key, fallback) {
    return setting(key, fallback);
  })
  readonly property var ui: Shared.WorkspaceInteraction
  readonly property var ownWindow: root.QsWindow.window
  readonly property string monitorName: ownWindow && ownWindow.screen ? ownWindow.screen.name : ""
  readonly property var entries: service.workspacesFor(monitorName)
  readonly property bool scratchpadEnabled: setting("scratchpad", true) !== false
  // The bar runs in its own process with its own Service instance, but the
  // saved preference belongs to the standalone app. Read it through the
  // launcher when the scratchpad menu opens and toggle it with `paperland
  // follow`, like the names client, so both surfaces' checkmarks share one
  // saved setting.
  property bool followChecked: true
  function readFollowState(): void { if (!followStatus.running) followStatus.running = true; }
  function toggleFollow(): void {
    root.followChecked = !root.followChecked;
    followToggle.command = [root.executable, "follow", root.followChecked ? "on" : "off"];
    followToggle.running = true;
  }
  Process {
    id: followStatus
    command: [root.executable, "status"]
    stdout: StdioCollector {
      onStreamFinished: {
        try { root.followChecked = JSON.parse(text).scratchpadFollow; } catch (error) {}
      }
    }
  }
  Process {
    id: followToggle
    command: []
    stdout: StdioCollector { onStreamFinished: root.readFollowState() }
  }
  readonly property var scratchpadEntry: service.scratchpadForMonitor(monitorName)
  property var itemIds: []
  readonly property var currentEntry: ui.workspace === "special:scratchpad" ? scratchpadEntry
    : service.catalog.entries[ui.workspace] || null
  readonly property bool ownsUi: ui.host === root
  readonly property bool opened: explicitUi
  readonly property bool explicitUi: ownsUi && ["menu", "rename", "windows", "quick", "close", "remove"].indexOf(ui.mode) >= 0
  readonly property var moduleSlot: root.parent && root.parent.parent ? root.parent.parent : null
  // The host puts the left list at the top, the right list at the bottom and the
  // centre list in the middle of a vertical bar, with no budget exposed to widgets.
  // Walk its tree for the other modules' heights so the pill column stays out of
  // them. Instances of this widget are skipped: counting each other would loop.
  readonly property var surroundings: PillColumn.surroundings(PillColumn.findBar(moduleSlot), moduleSlot, root.moduleName)
  readonly property real heightCap: {
    var screenHeight = ownWindow && ownWindow.screen ? ownWindow.screen.height : 0;
    if (!moduleSlot) return Math.max(0, screenHeight - Style.space(8) * 2);
    return PillColumn.heightCap(moduleSlot.region, screenHeight, Style.space(8), surroundings);
  }
  readonly property real pillViewport: PillColumn.viewport(workspaceRow.implicitHeight,
    heightCap - menuButton.implicitHeight - toggleButton.implicitHeight, barSize)
  function pillVisible(item: Item): bool {
    if (!item) return false;
    return vertical ? PillColumn.fullyVisible(item.y, item.height, workspaceScroll.contentY, workspaceScroll.height)
      : PillColumn.intersects(item.x, item.width, workspaceScroll.contentX, workspaceScroll.width);
  }
  // A vertical column scrolls by wheel, so the active pill is kept in view there. Horizontal
  // bars never scrolled to it and have no wheel to scroll back, so they are left alone.
  function revealPill(item: Item): void {
    if (!item || !vertical) return;
    workspaceScroll.contentY = PillColumn.revealed(item.y, item.height, workspaceScroll.contentY,
      workspaceScroll.height, workspaceScroll.contentHeight);
  }
  // One wheel notch moves one pill; the column then settles on a whole pill.
  function scrollPills(delta: real): void {
    if (!vertical) return;
    followActive = false;
    workspaceScroll.contentY = PillColumn.wheeled(workspaceScroll.contentY, delta, barSize,
      workspaceScroll.height, workspaceScroll.contentHeight);
    pillSnap.restart();
  }
  Connections {
    target: workspaceScroll
    function onHeightChanged() { if (root.followActive && root.vertical) root.revealActive(); }
    function onContentHeightChanged() { if (root.followActive && root.vertical) root.revealActive(); }
  }
  Timer {
    id: pillSnap
    interval: 160
    onTriggered: workspaceScroll.contentY = PillColumn.settled(workspaceScroll.contentY, root.barSize,
      workspaceScroll.height, workspaceScroll.contentHeight)
  }
  property var pillTooltips: ({})
  function recordTooltip(id: int, text: string): void {
    if (pillTooltips[id] === text) return;
    var next = Object.assign({}, pillTooltips);
    next[id] = text;
    pillTooltips = next;
  }
  property int toggleRequests: 0
  implicitWidth: vertical ? barSize : Math.min(Pill.finiteWidth(setting("maxWidth", 640), 640), menuButton.implicitWidth + workspaceRow.implicitWidth + toggleButton.implicitWidth)
  implicitHeight: vertical ? menuButton.implicitHeight + workspaceScroll.height + toggleButton.implicitHeight : barSize
  readonly property int activeId: { var active = entries.find(function(e) { return e.active; }); return active ? active.id : 0; }
  // The active pill stays in view until the user scrolls by hand. A rebuilt widget lays
  // its pills out at the horizontal size before the host injects the vertical one, and the
  // column's room arrives after the other modules, so one early reveal would land wrong.
  property bool followActive: true
  function revealActive(): void { revealPill(workspaceRepeater.itemAt(itemIds.indexOf(activeId))); }
  onActiveIdChanged: { followActive = true; Qt.callLater(revealActive); }
  // The host checks click targets last-registered first; keep the fixed buttons
  // after every pill so a pill never shadows them.
  onItemIdsChanged: Qt.callLater(function() { menuButton.syncClickRegistration(); toggleButton.syncClickRegistration(); })
  onEntriesChanged: {
    var ids = entries.map(function(e) { return e.id; });
    if (JSON.stringify(ids) !== JSON.stringify(itemIds)) itemIds = ids;
    // The quick menu belongs to no Desktop, so Desktop changes never close it.
    // The removal card keeps its own copy of the Desktop it is removing.
    if (ownsUi && !currentEntry && ui.mode !== "quick" && ui.mode !== "remove") close();
  }

  // Quick menu. The menu is a pure view; status reads and commands run here
  // through the configured launcher, and it shows only what status confirmed.
  readonly property bool quickOpen: ownsUi && ui.mode === "quick"
  property var quickStatus: null
  property string quickError: ""
  property int quickRuntime: -1
  // The running command's key, held until its sequence's last step finishes.
  property string quickPending: ""
  // Survives closing, so a failure after Search or Settings closed the menu
  // is still visible when it reopens; the next command clears it.
  property string quickAlert: ""
  property var quickSteps: []
  // Hyprland's scrolling:focus_fit_method as last read back: 0, 1, or -1 unknown.
  property int quickCentering: -1
  property string quickCenteringError: ""
  // Bumped when a command starts; a status read that overlapped it is discarded.
  property int quickWrites: 0
  readonly property var quickFailures: ({ minimap: "Couldn’t change Minimap visibility.", mode: "Couldn’t change Strip mode.",
    follow: "Couldn’t change Follow Scratchpad.", centering: "Couldn’t change Center focused column.",
    search: "Couldn’t open Search windows.", settings: "Couldn’t open Paperland Settings.",
    "runtime-start": "Couldn’t start Paperland. Retry or check the configured launcher.",
    "runtime-stop": "Couldn’t stop Paperland. Resolve unsaved Settings changes or a pending Save, then retry." })
  onQuickOpenChanged: {
    // A reopened menu must not present an earlier reading as current.
    quickStatus = null; quickError = ""; quickRuntime = -1; quickCentering = -1; quickCenteringError = "";
    if (quickOpen) { quickMenu.reset(); readQuickStatus(); }
  }
  function toggleQuick(): void {
    if (quickOpen) { close(); return; }
    if (Native.Runtime.sendMenu.opened) return;
    ui.explicitOpen(root, menuButton, 0, "quick");
  }
  // Paperland status and Hyprland's centering are read side by side, each
  // skipped while its previous read is still running.
  function readQuickStatus(): void {
    if (!quickOpen || quickWrite.running || quickPending !== "") return;
    if (!quickStatusProcess.running && !quickInstances.running) {
      quickStatusProcess.expired = false;
      quickStatusProcess.serial = quickWrites;
      quickStatusProcess.running = true;
      quickStatusTimeout.restart();
    }
    if (!quickCenteringRead.running) {
      quickCenteringRead.expired = false;
      quickCenteringRead.serial = quickWrites;
      quickCenteringRead.running = true;
      quickCenteringTimeout.restart();
    }
  }
  function receiveQuickStatus(code: int, text: string, serial: int): void {
    if (!quickOpen || quickPending !== "" || serial !== quickWrites) return;
    var status = code === 0 ? quickMenu.parseStatus(text, Quickshell.screens.length) : null;
    if (status) {
      quickStatus = status; quickRuntime = 1; quickError = "";
      return;
    }
    // A failed IPC call also happens for an unresponsive or malformed runtime.
    // Confirm absence through the exact launcher's selected config and display.
    quickStatus = null;
    quickInstances.serial = serial;
    quickInstances.expired = false;
    quickInstances.running = true;
    quickInstancesTimeout.restart();
  }
  function receiveQuickInstances(code: int, text: string, serial: int): void {
    if (!quickOpen || quickPending !== "" || serial !== quickWrites) return;
    quickStatus = null;
    quickRuntime = code === 0 && quickMenu.parseStopped(text) ? 0 : -1;
    quickError = quickRuntime === 0 ? "" : "Paperland status unavailable";
  }
  function receiveQuickCentering(code: int, text: string, serial: int): void {
    if (!quickOpen || quickPending !== "" || serial !== quickWrites) return;
    quickCentering = code === 0 ? quickMenu.parseCentering(text) : -1;
    quickCenteringError = code !== 0 ? "Couldn’t read column centering from Hyprland."
      : quickCentering < 0 ? "Hyprland reported an unsupported column centering value." : "";
  }
  /**
   * Maps a menu choice to command steps from confirmed state. `expect` is the
   * exact output that means success: `peek` and `follow` answer true and
   * `hyprctl eval` answers ok; the rest return void, so exit 0 with empty
   * output is success. Steps run the launcher unless they name a `command`.
   */
  function chooseQuick(action: string): void {
    var status = quickStatus;
    if (quickPending !== "" || quickWrite.running) return;
    if (action === "runtime" && (quickRuntime === 0 || quickRuntime === 1)) {
      runQuick(quickRuntime === 0 ? "runtime-start" : "runtime-stop",
        [quickRuntime === 0 ? {args: ["start-hidden"]} : {args: ["stop-safe"], expect: "true"}]);
      return;
    }
    if (!status) return;
    if (action === "search" || action === "settings") {
      close();
      runQuick(action, [{ args: [action] }]);
    } else if (action === "minimap") runQuick("minimap", [{ args: [status.visible > 0 ? "hide" : "show"] }]);
    else if (action === "follow") runQuick("follow", [{ args: ["follow", status.follow ? "off" : "on"], expect: "true" }]);
    else if (action === "mode-pinned") runQuick("mode", [{ args: ["pin", "true"] }]);
    else if (action === "mode-peek") runQuick("mode", [{ args: ["peek", "on"], expect: "true" }]);
    else if (action === "mode-manual")
      runQuick("mode", (status.pinned ? [{ args: ["pin", "false"] }] : []).concat([{ args: ["peek", "off"], expect: "true" }]));
    // Fixed Lua literals, as the centering shortcut sets; nothing read is interpolated.
    else if (action === "centering" && (quickCentering === 0 || quickCentering === 1))
      runQuick("centering", [{ command: ["hyprctl", "eval", quickCentering === 0
        ? "hl.config({ scrolling = { focus_fit_method = 1 } })"
        : "hl.config({ scrolling = { focus_fit_method = 0 } })"], expect: "ok" }]);
  }
  function runQuick(key: string, steps: var): void {
    quickPending = key; quickAlert = ""; quickSteps = steps;
    nextQuickStep();
  }
  function nextQuickStep(): void {
    var step = quickSteps[0];
    quickSteps = quickSteps.slice(1);
    quickWrites++;
    quickWrite.expired = false;
    quickWrite.expected = step.expect || "";
    quickWrite.command = step.command || [root.executable].concat(step.args);
    quickWrite.running = true;
    quickWriteTimeout.restart();
  }
  // A sequence stops at its first failure; status is re-read either way.
  function finishQuickStep(succeeded: bool): void {
    if (succeeded && quickSteps.length) { nextQuickStep(); return; }
    if (!succeeded) quickAlert = quickFailures[quickPending] || "";
    quickSteps = []; quickPending = "";
    readQuickStatus();
  }
  Timer { interval: 1000; repeat: true; running: root.quickOpen; onTriggered: root.readQuickStatus() }
  Process {
    id: quickStatusProcess
    property bool expired: false
    property int serial: 0
    command: [root.executable, "status"]
    stdout: StdioCollector { id: quickStatusOutput }
    onExited: function(code) {
      quickStatusTimeout.stop();
      var started = serial;
      if (!expired) Qt.callLater(function() { root.receiveQuickStatus(code, quickStatusOutput.text, started); });
    }
  }
  Timer {
    id: quickStatusTimeout
    interval: 2000
    onTriggered: { quickStatusProcess.expired = true; quickStatusProcess.running = false; root.receiveQuickStatus(-1, "", quickStatusProcess.serial); }
  }
  Process {
    id: quickInstances
    property bool expired: false
    property int serial: 0
    command: [root.executable, "instances"]
    stdout: StdioCollector { id: quickInstancesOutput }
    onExited: function(code) {
      quickInstancesTimeout.stop();
      var started = serial;
      if (!expired) Qt.callLater(function() { root.receiveQuickInstances(code, quickInstancesOutput.text, started); });
    }
  }
  Timer {
    id: quickInstancesTimeout
    interval: 2000
    onTriggered: { quickInstances.expired = true; quickInstances.running = false; root.receiveQuickInstances(-1, "", quickInstances.serial); }
  }
  Process {
    id: quickWrite
    property bool expired: false
    property string expected: ""
    command: []
    stdout: StdioCollector { id: quickWriteOutput }
    onExited: function(code) {
      quickWriteTimeout.stop();
      if (!expired) Qt.callLater(function() {
        root.finishQuickStep(code === 0 && (quickWrite.expected === "" || quickWriteOutput.text.trim() === quickWrite.expected));
      });
    }
  }
  Process {
    id: quickCenteringRead
    property bool expired: false
    property int serial: 0
    command: ["hyprctl", "getoption", "scrolling:focus_fit_method", "-j"]
    stdout: StdioCollector { id: quickCenteringOutput }
    onExited: function(code) {
      quickCenteringTimeout.stop();
      var started = serial;
      if (!expired) Qt.callLater(function() { root.receiveQuickCentering(code, quickCenteringOutput.text, started); });
    }
  }
  Timer {
    id: quickCenteringTimeout
    interval: 2000
    onTriggered: { quickCenteringRead.expired = true; quickCenteringRead.running = false; root.receiveQuickCentering(-1, "", quickCenteringRead.serial); }
  }
  Timer {
    id: quickWriteTimeout
    // Starting waits for bridge checks and the full QML runtime to load.
    interval: root.quickPending === "runtime-start" ? 10000 : 2000
    onTriggered: { quickWrite.expired = true; quickWrite.running = false; root.finishQuickStep(false); }
  }
  function entryFor(id) { return entries.find(function(e) { return e.id === id; }) || null; }
  function previewRow(entry: var): var {
    if (!entry) return null;
    if (!entry.special) return root.service.rows[entry.id] || null;
    for (var i = 0; i < root.service.rowIds.length; i++) {
      var row = root.service.rows[root.service.rowIds[i]];
      if (row && row.name === entry.id && row.monitor === root.monitorName) return row;
    }
    return null;
  }
  QtObject { id: passiveOwner; function close() { if (root.ownsUi && root.ui.mode === "hover") root.close(); } }
  // The bar's pill and its hover card (an xdg_popup of the bar layer) can stay
  // hovered after the pointer leaves for a client window, even with continuous
  // motion: no exit reaches Qt, so the card would never dismiss. While one is
  // open, compare against the compositor's cursor; two readings outside the
  // pill and card in a row outlast the 150 ms transit grace before closing it.
  // ponytail: polls hyprctl twice a second only while a hover card is open;
  // drop it once the compositor or Qt delivers the leave.
  function hoverRects(): var {
    var window = root.ownWindow, screen = window ? window.screen : null;
    if (!screen || !root.ui.anchor) return [];
    var pill = window.itemPosition(root.ui.anchor);
    return PreviewGeometry.hoverRects(
      { width: window.width, height: window.height,
        anchors: { left: window.anchors.left, top: window.anchors.top },
        margins: { left: window.margins.left, top: window.margins.top, right: window.margins.right, bottom: window.margins.bottom } },
      { x: screen.x, y: screen.y, width: screen.width, height: screen.height },
      { x: pill.x, y: pill.y, width: root.ui.anchor.width, height: root.ui.anchor.height },
      { x: preview.anchor.rect.x, y: preview.anchor.rect.y, width: preview.width, height: preview.height });
  }
  Timer {
    id: hoverAudit
    property int outside: 0
    interval: 500
    repeat: true
    running: root.ownsUi && root.ui.mode === "hover" && !root.ui.held
    onRunningChanged: outside = 0
    onTriggered: if (!cursorProbe.running) cursorProbe.running = true
  }
  Process {
    id: cursorProbe
    command: ["hyprctl", "-j", "cursorpos"]
    stdout: StdioCollector { id: cursorOutput }
    onExited: function(code) {
      if (code !== 0 || !hoverAudit.running) return;
      var cursor;
      try { cursor = JSON.parse(cursorOutput.text); } catch (error) { return; }
      // A reply without coordinates is not evidence the pointer left.
      if (!cursor || typeof cursor.x !== "number" || typeof cursor.y !== "number") return;
      if (PreviewGeometry.cursorInside(cursor, root.hoverRects())) hoverAudit.outside = 0;
      else if (++hoverAudit.outside >= 2) root.close();
    }
  }
  QtObject { id: explicitOwner; function close() { root.close(); } }
  function openPreviewMenu(address: string, position: point, source: Item): void {
    // Qt includes the popup offset but omits its root layer's placement.
    var global = source.mapToGlobal(0, 0), scene = source.mapToItem(null, 0, 0);
    var base = root.ownWindow.contentItem.mapToGlobal(0, 0);
    var window = root.ownWindow, screen = window.screen;
    var x = window.anchors.left ? window.margins.left : screen.width - window.width - window.margins.right;
    var y = window.anchors.top ? window.margins.top : screen.height - window.height - window.margins.bottom;
    Native.Runtime.sendMenu.openFor(address, screen, Qt.point(position.x + global.x - scene.x - base.x + x,
      position.y + global.y - scene.y - base.y + y), barSlab());
  }
  // The bar slab is not part of the area a menu may use, whichever popup asks for one.
  function barSlab(): var {
    var window = root.ownWindow, slab = { left: 0, top: 0, right: 0, bottom: 0 };
    if (!window || !window.screen) return slab;
    var screen = window.screen;
    var x = window.anchors.left ? window.margins.left : screen.width - window.width - window.margins.right;
    var y = window.anchors.top ? window.margins.top : screen.height - window.height - window.margins.bottom;
    if (vertical) {
      if (window.anchors.left) slab.left = x + window.width;
      else slab.right = screen.width - x;
    } else if (window.anchors.top) slab.top = y + window.height;
    else slab.bottom = screen.height - y;
    return slab;
  }
  function canPreview(): bool { return !Native.Runtime.sendMenu.opened && !!bar && (!bar.activePopout || bar.activePopout === passiveOwner) && (!ui.opened || ui.mode === "hover"); }
  function close() { if (ownsUi) ui.close(); }
  function hide() { close(); }
  Connections {
    target: Native.Runtime.sendMenu
    function onStarting() { if (root.ownsUi) { root.ui.held = true; activation.stop(); } }
    function onSubmittingChanged() { if (Native.Runtime.sendMenu.submitting) root.close(); }
    function onOpenedChanged() {
      if (Native.Runtime.sendMenu.opened || !root.ownsUi) return;
      root.ui.held = false;
      if (root.explicitUi) Qt.callLater(function() {
        if (!root.explicitUi || Native.Runtime.sendMenu.opened) return;
        panel.focusPrimed = false;
        panel.beginFocusPrime();
        if (panel.focusTarget) panel.focusTarget.forceActiveFocus();
      });
    }
  }
  function open(): void {
    if (Native.Runtime.sendMenu.opened) return;
    var entry = entries.find(function(e) { return e.active; });
    if (!entry) return;
    var button = workspaceRepeater.itemAt(itemIds.indexOf(entry.id));
    revealPill(button);
    ui.explicitOpen(root, button, entry.id, "menu");
    menu.selectedIndex = 0;
  }
  function openFocused() { if (entries.some(function(e) { return e.focused; })) open(); }
  function rectOf(item: Item): var {
    var point = ownWindow ? ownWindow.itemPosition(item) : Qt.point(0, 0);
    return { x: point.x, y: point.y, width: item.width, height: item.height };
  }
  // Where the host actually placed every visible module of a region, in bar window coordinates.
  function slotRects(region: string): var {
    var slots = PillColumn.regionSlots(PillColumn.findBar(moduleSlot), region), out = [];
    for (var i = 0; i < slots.length; i++) {
      if (!(slots[i].height > 0)) continue;
      var point = ownWindow ? ownWindow.itemPosition(slots[i]) : Qt.point(0, 0);
      out.push({ name: slots[i].moduleName, x: point.x, y: point.y, width: slots[i].width, height: slots[i].height });
    }
    return out;
  }
  // The host's own tooltip state, when the plugin facade exposes it; a third-party widget
  // normally sees only the facade, so absence is reported rather than guessed.
  function hostTooltip(): var {
    var host = root.bar;
    if (!host || !("tooltipShown" in host)) return { reachable: false };
    var target = "tooltipTarget" in host ? host["tooltipTarget"] : null;
    return { reachable: true, shown: !!host["tooltipShown"], target: target ? String(target.objectName || "") : "" };
  }
  function snapshot() {
    return { monitor: monitorName, barPosition: bar ? bar.position : "", mode: ownsUi ? ui.mode : "", workspace: ownsUi ? ui.workspace : 0,
      column: { height: root.implicitHeight, viewportHeight: workspaceScroll.height,
        contentHeight: workspaceScroll.contentHeight, contentY: workspaceScroll.contentY,
        cap: root.heightCap, toggleRequests: root.toggleRequests, followActive: root.followActive,
        around: root.surroundings },
      hover: { hostIsWidget: ui.host === root, anchorName: ui.anchor ? ui.anchor.objectName : "",
        dwellRunning: ui.dwell.running, dismissRunning: ui.dismiss.running,
        blockedUntilEntry: ui.blockedUntilEntry, held: ui.held, cardHovered: ui.cardHovered,
        canPreview: root.canPreview() },
      preview: { row: !!passivePreview.row, vertical: !!passivePreview.row && passivePreview.row.vertical === true },
      previewZoom: passivePreview.mapZoom, previewOpen: preview.open, editorOpen: panel.open && ui.mode === "rename",
      nameBusy: Native.Runtime.names.busy, nameMessage: Native.Runtime.names.message, nameRequest: Native.Runtime.names.requestId,
      editorCaptureId: editor.draftCapture ? editor.draftCapture.id : 0,
      activationError: service.activationError,
      foreignPopout: !!bar.activePopout && bar.activePopout !== passiveOwner && bar.activePopout !== explicitOwner,
      popup: { x: preview.anchor.rect.x, y: preview.anchor.rect.y, width: preview.width, height: preview.height },
      panel: { open: panel.open, focused: !!panel.focusTarget && panel.focusTarget.activeFocus, x: panel.cardOrigin.x, y: panel.cardOrigin.y, width: panel.contentWidth,
        height: panel.contentHeight, availableWidth: panel.availableCardWidth, availableHeight: panel.availableCardHeight },
      items: itemIds.map(function(id, index) {
        var button = workspaceRepeater.itemAt(index);
        var point = button && root.ownWindow ? root.ownWindow.itemPosition(button) : Qt.point(0, 0);
        return { id: id, entry: root.entryFor(id), x: point.x, y: point.y, width: button ? button.width : 0, height: button ? button.height : 0,
          tooltip: root.pillTooltips[id] || "", reachable: root.pillVisible(button) };
      }),
      menuButton: root.rectOf(menuButton), toggleButton: root.rectOf(toggleButton), hostTooltip: root.hostTooltip(),
      layout: { left: root.slotRects("left"), center: root.slotRects("center"), right: root.slotRects("right") },
      scratchpad: { visible: scratchpadPill.visible, entry: scratchpadPill.entry,
        x: root.ownWindow ? root.ownWindow.itemPosition(scratchpadPill).x : 0,
        y: root.ownWindow ? root.ownWindow.itemPosition(scratchpadPill).y : 0,
        width: scratchpadPill.width, height: scratchpadPill.height } };
  }
  IpcHandler {
    target: "paperlandBar"
    enabled: Quickshell.screens.length > 0 && root.monitorName === Quickshell.screens[0].name
    function open(): void { root.broadcast("openFocused"); }
    function close(): void { root.broadcast("hide"); }
    function status(): string {
      var widgets = root.bar && root.bar.moduleWidgets ? root.bar.moduleWidgets(root.moduleName) : [root];
      return JSON.stringify(widgets.map(function(widget) { return widget.snapshot(); }));
    }
    // Every widget in this process registers with the shared runtime, so one
    // enabled handler reports all bar previews.
    function captures(detail: string): string { return Native.Runtime.captureReport("bar", detail === "detail", []); }
    function identity(): string { return Native.Runtime.identityReport(); }
  }
  function captureRecords(): var {
    return passivePreview.captureRecords("bar-preview").concat(explicitPreview.captureRecords("bar-preview"));
  }
  function toggle() { if (explicitUi) close(); else open(); }
  function rename(clearing) {
    if (!currentEntry) return;
    ui.mode = "rename";
    editor.begin(currentEntry.id, currentEntry.name, clearing);
  }
  function activate(address) { activation.address = address; close(); activation.restart(); }
  // The exact representative under the pointer in the hovered pill while its
  // passive preview is open. Derived from the pill's own pointer position, so a
  // pointer already resting on an icon when the preview opens highlights it,
  // rebuilt slot delegates cannot leave it stale, and a closed or moved
  // representative drops out. It never focuses, pans or claims the map's hover.
  readonly property string pillHighlight: {
    if (!ownsUi || ui.mode !== "hover" || !ui.anchor || !currentEntry || currentEntry.special
        || typeof ui.anchor.pressTarget !== "function") return "";
    var target = ui.anchor.pressTarget();
    var address = target && target.slot ? target.slot.representative : "";
    return address && currentEntry.windows.some(function(w) { return w.address === address; }) ? address : "";
  }
  function openWorkspaceList(id: int, button: var): void {
    root.ui.explicitOpen(root, button, id, "windows");
  }
  // Title of the globally focused client when it belongs to this workspace;
  // never a last-focused guess, so a workspace losing focus loses its title.
  function focusedTitle(entry: var): string {
    var address = service.nativeFocus;
    if (!entry || !address) return "";
    var window = entry.windows.find(function(w) { return w.address === address; });
    return window && window.title ? window.title : "";
  }
  // The inherited #a55eab gave white labels 4.39:1; #a35ca9 is the smallest
  // perceptual change reaching 4.5:1 (checked by StripColumns.test.js).
  readonly property color activeFill: "#a35ca9"
  readonly property color darkInk: "#08030a"
  readonly property int glyphSize: 14
  // Width pressure: icons share what maxWidth leaves after the menu, toggle,
  // Scratchpad pill and every pill's label, then reduce behind a +N chip.
  property var pillBases: ({})
  function notePillBase(id: int, width: real): void {
    if (pillBases[id] === width) return;
    var next = Object.assign({}, pillBases);
    next[id] = width;
    pillBases = next;
  }
  readonly property real iconSpace: {
    var used = menuButton.implicitWidth + toggleButton.implicitWidth
      + (scratchpadPill.visible ? scratchpadPill.width + workspaceRow.spacing : 0);
    itemIds.forEach(function(id) { used += (pillBases[id] || 0) + workspaceRow.spacing; });
    return Math.max(0, Pill.finiteWidth(setting("maxWidth", 640), 640) - used);
  }
  // Pills that show icons share the budget: "all" divides it among the pills
  // that qualify (active or not, never one that shows nothing), the other
  // modes among the single active or hovered pill. Derived from settings and
  // entries only, so it never depends on a pill's own slot result.
  readonly property int iconPillCount: {
    if (!pillSettings.showIcons) return 1;
    if (pillSettings.iconsOn !== "all") return 1;
    var shown = entries.filter(function(entry) { return !entry.special && entry.windows.length > 0; }).length;
    return Math.max(1, shown);
  }
  readonly property int floatGap: 5
  // How long a pill keeps its last good columns while a fresh snapshot is on
  // its way (60 ms row refresh versus the 150 ms Lua settle plus transport).
  readonly property int columnHoldMs: 1000
  // Coalesces stale-snapshot requests from every pill into one native pull.
  Timer { id: columnRequest; interval: 250; onTriggered: Native.Runtime.requestStripColumns() }
  function requestFreshColumns(): void { if (!columnRequest.running) columnRequest.start(); }
  // Logical px of a stack slot's ring band around its glyph: the list target.
  readonly property int ringBand: 3
  // A stack ring or group badge opens the window list so every member stays
  // reachable; the glyph itself activates its exact representative.
  function activatePillSlot(slot: var, id: int, button: var, list: bool): void {
    if (list) openWorkspaceList(id, button);
    else activate(slot.representative);
  }
  // Groups follow the shared desktop-entry resolver, so two classes that
  // resolve to one entry share a group; unresolved classes stay distinct.
  function appIdentity(app: string): string {
    var entry = Native.Runtime.appEntry(app);
    return entry && entry.id ? "entry:" + entry.id : "class:" + app;
  }
  Timer { id: activation; property string address: ""; interval: 40; onTriggered: root.service.activate(activation.address) }
  Connections {
    target: root.ui
    function onModeChanged() {
      if (!root.explicitUi) return;
      Qt.callLater(function() {
        if (root.ui.mode === "windows") explicitPreview.forceActiveFocus();
        else if (root.ui.mode === "menu") menu.forceActiveFocus();
        else if (root.ui.mode === "quick") quickMenu.forceActiveFocus();
      });
    }
  }
  Connections {
    target: root.bar
    function onPositionChanged() { root.ui.forgetPointer(); }
    function onActivePopoutChanged() { if (root.ownsUi && root.ui.opened && root.bar.activePopout && root.bar.activePopout !== passiveOwner && root.bar.activePopout !== explicitOwner) root.close(); }
  }
  Binding {
    target: Native.Runtime.names
    property: "executable"
    value: root.executable
  }
  Component.onCompleted: {
    Native.Runtime.registerCaptureSurface(root);
    // The bar loads this plugin directory and the runtime tree beneath it.
    var plugin = Native.Runtime.localPath(Qt.resolvedUrl("."));
    Native.Runtime.computeIdentity([plugin, plugin + "/paperland"]);
  }
  Component.onDestruction: { if (ownsUi) ui.close(); Native.Runtime.unregisterCaptureSurface(root); }

  Paper.ActivationNotice { service: root.service; noticeScreen: root.ownWindow ? root.ownWindow.screen : null; eligible: root.entries.some(function(entry) { return entry.focused; }) }

  WidgetButton {
    id: menuButton
    objectName: "paperland-menu-button"
    anchors.left: parent.left
    anchors.top: root.vertical ? parent.top : undefined
    bar: root.bar
    fixedHeight: root.vertical ? root.barSize : -1
    hasVisualContent: true
    labelVisible: false
    fixedWidth: root.vertical ? root.barSize : 16 + scaledHorizontalMargin * 2
    // The host shows this on hover; it stays quiet while the menu is open.
    tooltipText: root.quickOpen ? "" : "Paperland menu"
    Accessible.role: Accessible.Button
    Accessible.name: "Paperland menu"
    Accessible.onPressAction: triggerPress(Qt.LeftButton)
    onPressed: function(button) { if (button === Qt.LeftButton) root.toggleQuick(); }
    Rectangle {
      anchors.centerIn: parent
      width: 22; height: 22
      color: root.quickOpen ? quickMenu.tint(Color.accent, 0.18) : "transparent"
    }
    Canvas {
      id: menuMark
      anchors.centerIn: parent
      width: 16; height: 16
      onPaint: quickMenu.paintMark(getContext("2d"), width, menuButton.foreground, root.quickOpen ? Color.accent : menuButton.foreground)
      Connections { target: root; function onQuickOpenChanged() { menuMark.requestPaint(); } }
      Connections { target: menuButton; function onForegroundChanged() { menuMark.requestPaint(); } }
    }
  }
  Flickable {
    id: workspaceScroll
    anchors.left: root.vertical ? parent.left : menuButton.right
    anchors.top: root.vertical ? menuButton.bottom : undefined
    width: root.vertical ? root.barSize : Math.max(0, root.width - menuButton.width - toggleButton.width)
    // Never parent.height: the host Loader sizes this widget from its own
    // implicitHeight, which reads this height, so an edge flip looped through it.
    height: root.vertical ? root.pillViewport : root.barSize
    contentWidth: workspaceRow.implicitWidth
    contentHeight: root.vertical ? workspaceRow.implicitHeight : height
    flickableDirection: root.vertical ? Flickable.VerticalFlick : Flickable.HorizontalFlick
    clip: true
    Grid {
      id: workspaceRow
      columns: root.vertical ? 1 : root.itemIds.length + 1
      Repeater {
        id: workspaceRepeater
        model: root.itemIds
        delegate: WidgetButton {
          id: workspaceButton
          required property int modelData
          readonly property var entry: root.entryFor(modelData)
          readonly property bool urgent: !!root.service.urgentByWorkspace[modelData]
          readonly property var pillRow: entry && !entry.special ? root.service.rows[modelData] || null : null
          // Hover reveal stays while this pill's passive preview is open, so
          // the transit to the preview keeps the pill's geometry; the pill only
          // grows around the pointer, never away from it.
          readonly property bool previewing: root.ownsUi && root.ui.mode === "hover" && root.ui.anchor === workspaceButton
          readonly property bool iconsShown: !!entry && !root.vertical && Pill.iconsVisible(root.pillSettings,
            { active: entry.active, hovered: pillHovered || previewing })
          // Label-only width, reported to the bar's width budget (icons excluded,
          // so the budget never depends on the slots it decides).
          readonly property real baseWidth: pillVisual.labelItem.implicitWidth + 18
          onBaseWidthChanged: root.notePillBase(modelData, baseWidth)
          readonly property var slotOptions: ({ focusedAddress: root.service.focusedAddress,
            maxIcons: root.pillSettings.maxIcons, groupByApp: root.pillSettings.groupByApp, appKey: root.appIdentity,
            widthBudget: root.iconSpace / root.iconPillCount - 8,
            // ponytail: one pitch per mode; stack rings, two-digit badges and
            // the float gap can overshoot by a few px.
            slotPitch: root.glyphSize + 4 + (root.pillSettings.groupByApp ? Pill.BADGE.overhangX : 0), chipWidth: 22 })
          readonly property var stripColumns: iconsShown && pillRow && entry.layout === "scrolling"
            ? Native.Runtime.columnsForWorkspace(modelData) : null
          readonly property var freshColumns: stripColumns ? Pill.columnSlots(pillRow, stripColumns, slotOptions) : null
          // The row moves ~60 ms after a window event; the snapshot needs the
          // Lua settle, a launcher round trip and a file watch. Until it lands
          // the resolver refuses, and catalog order in between would split
          // stacks and drop parked dimming for a flash. Hold the last good
          // result for a bounded time, then fall back honestly.
          property var heldColumns: null
          property bool columnsStale: false
          readonly property var columnResult: {
            var state = Pill.holdColumns(heldColumns, freshColumns, Date.now(), root.columnHoldMs);
            return state.show;
          }
          onFreshColumnsChanged: {
            if (freshColumns) { heldColumns = { result: freshColumns, at: Date.now() }; columnsStale = false; columnHold.stop(); }
            else if (stripColumns) {
              columnsStale = true;
              root.requestFreshColumns();
              if (heldColumns && !columnHold.running) columnHold.restart();
            } else { heldColumns = null; columnsStale = false; columnHold.stop(); }
          }
          // Re-evaluates columnResult once the hold has lapsed.
          Timer { id: columnHold; interval: root.columnHoldMs; onTriggered: workspaceButton.heldColumns = null }
          readonly property var pillSlots: !iconsShown ? null
            : columnResult || Pill.catalogSlots(entry.windows, slotOptions)
          objectName: "paperland-workspace-" + modelData
          bar: root.bar
          hasVisualContent: true
          labelVisible: false
          fixedWidth: root.vertical ? root.barSize : pillVisual.labelItem.implicitWidth + 18
            + (iconGroup.visible ? (pillVisual.labelItem.visible ? 8 : 0) + iconGroup.implicitWidth : 0)
          fixedHeight: root.vertical ? root.barSize : -1
          dimmed: !entry || (!entry.active && entry.count === 0)
          // The host shows this 400 ms after hover, which is after the 180 ms preview
          // dwell, so a pending tooltip is cancelled when the popup takes the pill.
          tooltipText: root.vertical && !root.ui.owns(workspaceButton) ? pillVisual.labelItem.accessibleName : ""
          onTooltipTextChanged: root.recordTooltip(modelData, tooltipText)
          Component.onCompleted: { root.notePillBase(modelData, baseWidth); root.recordTooltip(modelData, tooltipText); }
          // Pills scrolled out of the column keep their geometry, which the host
          // would still match against clicks meant for the buttons and modules there.
          pressable: root.pillVisible(workspaceButton)
          function hideTooltipWhileOwned(): void { if (root.ui.owns(workspaceButton)) hideOwnTooltip(); }
          Connections {
            target: root.ui
            function onOpenedChanged() { workspaceButton.hideTooltipWhileOwned(); }
            function onAnchorChanged() { workspaceButton.hideTooltipWhileOwned(); }
          }
          onWheelMoved: function(delta) { root.scrollPills(delta); }
          Accessible.role: Accessible.Button
          Accessible.name: pillVisual.labelItem.accessibleName + (urgent ? ", needs attention" : "")
          // Accessibility has no pointer: the pill's own action is the workspace,
          // never an icon that live hover happens to resolve.
          Accessible.onPressAction: if (entry) { root.close(); root.service.activateWorkspace(modelData); }
          // Icon slots' HoverHandlers take hover from the base MouseArea
          // (a sibling), so tooltipHovered drops over an icon. A handler on
          // the pill itself spans label and icons alike.
          HoverHandler {
            id: pillHoverArea
            // Relocating the bar can leave the pill hovered without a new change signal.
            onPointChanged: {
              if (workspaceButton.pillHovered && workspaceButton.entry && !root.ui.dwell.running && root.ui.mode === ""
                  && root.ui.pointerAnchor !== workspaceButton)
                root.ui.enter(root, workspaceButton, workspaceButton.modelData);
            }
          }
          // A quick second click near the first is a double click. Omarchy's
          // module MouseArea handles only clicks and propagates it down to the
          // full-width center gesture area, which accepts it (toggling bar
          // transparency) and so suppresses the host click: the icon press
          // would be lost. Accepting it here for icon targets keeps the press;
          // elsewhere it still reaches the host unchanged. Presses never reach
          // this area: the host MouseArea above takes them, and without hover
          // it leaves the icons' HoverHandlers alone.
          MouseArea {
            objectName: "paperland-pill-double-click"
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            onDoubleClicked: function(mouse) { mouse.accepted = workspaceButton.pressIcon(); }
          }
          readonly property bool pillHovered: visible && interactive && !concealed && pillHoverArea.hovered
          onPillHoveredChanged: {
            if (pillHovered && entry) root.ui.enter(root, workspaceButton, modelData);
            else root.ui.leave(root, workspaceButton);
          }
          // The icon target under the pointer, from geometry at press time.
          // Slot delegates are rebuilt on every catalog refresh, so hover state
          // they held can be gone when a press lands; this pill's own handler
          // persists. Returns {index, slot, list, chip} or null.
          function pressTarget(): var {
            if (!pillHoverArea.hovered || !pillSlots) return null;
            var p = workspaceButton.mapToItem(iconGroup, pillHoverArea.point.position.x, pillHoverArea.point.position.y);
            for (var i = 0; i < slotRepeater.count && i < pillSlots.slots.length; i++) {
              var item = slotRepeater.itemAt(i);
              if (!item) continue;
              var x = p.x - item.x, y = p.y - item.y;
              if (x < 0 || y < 0 || x >= item.width || y >= item.height) continue;
              var slot = pillSlots.slots[i], band = slot.stack ? root.ringBand : 0;
              var onGlyph = x >= band && x < band + root.glyphSize && y >= band && y < band + root.glyphSize;
              // A group's badge is a corner rectangle on its glyph (its own
              // target, drawn above it); a stack's ring surrounds the glyph.
              var gx = slot.floatStart ? root.floatGap : 0;
              var onBadge = slot.group && Pill.rectContains(
                Pill.badgeRect(slot.count, gx, Pill.BADGE.overhangY, root.glyphSize), x, y);
              return { index: i, slot: slot, chip: false,
                list: slot.group ? onBadge : slot.stack && !onGlyph };
            }
            if (overflowChip.visible && p.x >= overflowChip.x && p.x < overflowChip.x + overflowChip.width
                && p.y >= overflowChip.y && p.y < overflowChip.y + overflowChip.height)
              return { index: -1, slot: null, chip: true, list: true };
            return null;
          }
          // Acts on the icon target under the pointer; false when there is none.
          function pressIcon(): bool {
            var target = pressTarget();
            if (!target) return false;
            if (target.chip) root.openWorkspaceList(modelData, workspaceButton);
            else root.activatePillSlot(target.slot, modelData, workspaceButton, target.list);
            return true;
          }
          // Omarchy's module-level MouseArea takes every press in the slot and
          // forwards only the button to this pill's triggerPress, so a left
          // press resolves to the icon or overflow chip under the pointer.
          onPressed: function(button) {
            if (!entry) return;
            if (button === Qt.LeftButton) {
              if (pressIcon()) return;
              root.close(); root.service.activateWorkspace(modelData);
            }
            else if (button === Qt.RightButton) {
              menu.selectedIndex = 0;
              root.ui.explicitOpen(root, workspaceButton, modelData, "menu");
            }
          }
          // The scratchpad-open treatment shared with the minimap: the active desktop pill
          // fades beneath a dashed accent outline (see WorkspacePillVisual).
          Shared.WorkspacePillVisual {
            id: pillVisual
            anchors.fill: parent
            entry: workspaceButton.entry
            vertical: root.vertical
            scratchpadShown: !!workspaceButton.entry && workspaceButton.entry.active
              && root.scratchpadEnabled && root.scratchpadEntry.active
            color: workspaceButton.entry && workspaceButton.entry.active ? root.activeFill : "transparent"
            showId: root.pillSettings.showId
            showCount: root.pillSettings.showCount
            showName: root.pillSettings.showName
            title: root.pillSettings.showFocusedTitle && !root.vertical ? root.focusedTitle(workspaceButton.entry) : ""
            maximumWidth: root.pillSettings.showFocusedTitle ? 320 : 180
            foreground: workspaceButton.foreground
            fontFamily: workspaceButton.fontFamily
            fontSize: Style.font.body
            // App icons join the label row inside the pill (horizontal bars only).
              Row {
                id: iconGroup
                anchors.verticalCenter: parent.verticalCenter
                spacing: 4
                visible: !!workspaceButton.pillSlots
                  && (workspaceButton.pillSlots.slots.length > 0 || workspaceButton.pillSlots.truncated)
                Repeater {
                  id: slotRepeater
                  model: workspaceButton.pillSlots ? workspaceButton.pillSlots.slots : []
                  delegate: Item {
                    id: slot
                    required property var modelData
                    required property int index
                    readonly property color ink: workspaceButton.entry && workspaceButton.entry.active
                      ? "white" : workspaceButton.foreground
                    readonly property string iconUrl: Native.Runtime.iconForPill(modelData.app)
                    readonly property bool mono: root.pillSettings.iconStyle === "mono"
                    // Colour and mono draw the same resolved app icon; mono only
                    // desaturates it. The letter tile is the worst case: no icon
                    // resolves, or the image fails to load.
                    readonly property bool tileShown: iconUrl === "" || appImage.status === Image.Error
                    // Mono glyphs and letter tiles take the stronger of dark or
                    // light ink against the surface actually behind them. A
                    // transparent bar shows the wallpaper, so inactive pills
                    // follow the polarity of the bar's own foreground.
                    readonly property color surface: workspaceButton.entry && workspaceButton.entry.active ? root.activeFill
                      : root.bar && root.bar.transparent
                        ? (Pill.contrastRatio(workspaceButton.foreground, root.darkInk)
                          >= Pill.contrastRatio(workspaceButton.foreground, Qt.color("#ffffff")) ? root.darkInk : "#ffffff")
                        : root.bar ? root.bar.background : "#000000"
                    readonly property var surfaceInk: Pill.surfaceInk(slot.surface, root.darkInk, Qt.color("#ffffff"))
                    // Floating and pinned windows follow the column run after a gap.
                    readonly property int leadGap: modelData.floatStart ? root.floatGap : 0
                    // Every app group carries its count beside the glyph, a
                    // single window's included; strip stacks use the ring.
                    readonly property bool badged: modelData.group === true
                    // A stack's ring is its own target: a band of `ringBand`
                    // logical px around the glyph opens the window list, while
                    // the glyph itself activates the representative.
                    readonly property int ringBand: modelData.stack ? root.ringBand : 0
                    // A badged slot pads its top and bottom by the badge's vertical
                    // overhang so the glyph stays centred in the pill.
                    readonly property int padY: badged ? Pill.BADGE.overhangY : 0
                    objectName: "paperland-pill-slot-" + workspaceButton.modelData + "-" + modelData.representative
                    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
                    width: leadGap + glyph.width + 2 * ringBand + (badged ? Pill.BADGE.overhangX : 0)
                    height: glyph.height + 2 * (ringBand + padY)
                    Accessible.role: Accessible.Button
                    Accessible.name: "Activate " + Native.Runtime.nameFor(modelData.app)
                      + (badged || modelData.stack ? ", " + modelData.count + " windows" : "")
                      + ", workspace " + workspaceButton.modelData
                      + (modelData.parked ? ", outside view" : "")
                    Accessible.onPressAction: root.activatePillSlot(slot.modelData, workspaceButton.modelData, workspaceButton, false)
                    Item {
                      id: glyph
                      x: slot.leadGap + slot.ringBand; y: slot.ringBand + slot.padY
                      width: root.glyphSize; height: root.glyphSize
                      // Unknown or unloadable apps keep a letter tile through the
                      // same resolver, never another application's identity.
                      Rectangle {
                        objectName: "paperland-pill-tile"
                        anchors.fill: parent
                        radius: 4
                        visible: slot.tileShown
                        opacity: slot.modelData.parked ? 0.45 : 1
                        color: Qt.alpha(slot.surfaceInk.fill, 0.3)
                        Text {
                          objectName: "paperland-pill-tile-text"
                          anchors.centerIn: parent
                          text: Native.Runtime.nameFor(slot.modelData.app).charAt(0).toUpperCase() || "?"
                          color: slot.surfaceInk.ink
                          font { family: workspaceButton.fontFamily; pixelSize: 9; bold: true }
                        }
                      }
                      Image {
                        id: appImage
                        objectName: "paperland-pill-slot-image"
                        anchors.fill: parent
                        visible: !slot.mono && !slot.tileShown
                        source: slot.iconUrl
                        sourceSize.width: 28
                        sourceSize.height: 28
                        fillMode: Image.PreserveAspectFit
                        opacity: slot.modelData.parked ? 0.45 : 1
                      }
                      // Mono: the same icon in greyscale. Saturation -1 drops
                      // chroma only, so luminance and the logo's internal detail
                      // survive (a square icon stays an icon, not a solid block).
                      MultiEffect {
                        objectName: "paperland-pill-slot-mono"
                        anchors.fill: parent
                        source: appImage
                        visible: slot.mono && !slot.tileShown
                        saturation: -1.0
                        opacity: slot.modelData.parked ? 0.45 : 1
                      }
                      // The stack ring marks a shared slot; activating it opens
                      // the existing window list so every member stays reachable.
                      Rectangle {
                        objectName: "paperland-pill-ring"
                        anchors.fill: parent
                        // -1 keeps a pixel of fill between the ring and a
                        // focused pill's border.
                        anchors.margins: -1
                        radius: 5
                        visible: slot.modelData.stack
                        color: "transparent"
                        border.width: 1
                        border.color: Qt.alpha(slot.ink, 0.7)
                        Accessible.role: Accessible.Button
                        Accessible.name: "Window list for " + Native.Runtime.nameFor(slot.modelData.app)
                          + " stack, " + slot.modelData.count + " windows, workspace " + workspaceButton.modelData
                        Accessible.onPressAction: root.openWorkspaceList(workspaceButton.modelData, workspaceButton)
                      }
                    }
                    // A compact corner badge on the glyph's bottom-right: the icon
                    // stays the primary shape and the count reads as its own. Dark
                    // chip, white numerals (text contrast on any surface), with a
                    // ring in the surface colour that cuts it out of the glyph.
                    Rectangle {
                      id: badge
                      objectName: "paperland-pill-badge"
                      readonly property var rect: Pill.badgeRect(slot.modelData.count, glyph.x, glyph.y, glyph.width)
                      x: rect.x; y: rect.y
                      visible: slot.badged
                      width: rect.width
                      height: rect.height
                      radius: height / 2
                      color: root.darkInk
                      border.width: 1
                      border.color: slot.surface
                      opacity: slot.modelData.parked ? 0.6 : 1
                      Accessible.role: Accessible.Button
                      Accessible.name: "Window list for " + Native.Runtime.nameFor(slot.modelData.app)
                        + ", " + slot.modelData.count + " windows, workspace " + workspaceButton.modelData
                      Accessible.onPressAction: root.activatePillSlot(slot.modelData, workspaceButton.modelData, workspaceButton, true)
                      Text {
                        id: badgeText
                        anchors.centerIn: parent
                        text: String(slot.modelData.count)
                        color: "white"
                        font { family: workspaceButton.fontFamily; pixelSize: 8; bold: true }
                      }
                    }
                    Rectangle {
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.left: parent.left
                      anchors.leftMargin: -3
                      width: 1
                      height: 10
                      visible: slot.modelData.divider
                      // The non-colour parked cue: 0.7 alpha is 3:1 on the active fill.
                      color: Qt.alpha(slot.ink, 0.7)
                    }
                  }
                }
                Item {
                  id: overflowChip
                  readonly property var slots: workspaceButton.pillSlots
                  visible: !!slots && slots.truncated
                  anchors.verticalCenter: parent ? parent.verticalCenter : undefined
                  width: Math.max(14, overflowLabel.implicitWidth + 6)
                  height: 14
                  Accessible.role: Accessible.Button
                  Accessible.name: slots ? "+" + slots.hidden
                    + (root.pillSettings.groupByApp ? " more app groups, "
                      : workspaceButton.columnResult ? " more strip slots, " : " more windows, ")
                    + slots.omittedWindows + " windows, workspace " + workspaceButton.modelData : ""
                  Accessible.onPressAction: root.openWorkspaceList(workspaceButton.modelData, workspaceButton)
                  // Dark chip, white numerals: text contrast on any surface.
                  Rectangle {
                    anchors.fill: parent
                    radius: 3
                    color: root.darkInk
                  }
                  Text {
                    id: overflowLabel
                    anchors.centerIn: parent
                    text: overflowChip.slots ? "+" + overflowChip.slots.hidden : ""
                    color: "white"
                    font { family: workspaceButton.fontFamily; pixelSize: 9; bold: true }
                  }
                  HoverHandler { id: chipHover }
                  QQC.ToolTip {
                    visible: chipHover.hovered
                    delay: 300
                    text: overflowChip.Accessible.name
                  }
                }
              }
          }
          // A badge on the visible pill's top-right corner, clear of the raised count;
          // the label keeps its centered width and nothing about the pill animates.
          Shared.UrgentDot {
            objectName: "bar-pill-urgent-" + workspaceButton.modelData
            x: (workspaceButton.width + pillVisual.shape.width) / 2 - 4
            y: (workspaceButton.height - pillVisual.shape.height) / 2
            z: 5
            diameter: 6
            visible: workspaceButton.urgent
          }
        }
      }
      Shared.ScratchpadPill {
        id: scratchpadPill
        objectName: "paperland-scratchpad"
        barStyle: true
        // The open bar pill carries a white label: same 4.5:1 fill as Desktops.
        accent: root.activeFill
        barHeight: root.barSize
        pillEnabled: root.scratchpadEnabled
        showName: !root.vertical
        entry: root.scratchpadEntry
        shortcutBinding: root.service.scratchpadBinding
        open: root.scratchpadEntry.active
        // The shared entry is global: a scratchpad client that requested
        // attention marks every display's pill, open or closed.
        urgent: root.scratchpadEntry.windows.some(function(window) {
          return window.address !== root.service.focusedAddress && !!root.service.urgentAddresses[window.address];
        })
        foreground: root.barTheme ? root.barTheme.barForeground : "#dddddd"
        fontFamily: root.barTheme ? root.barTheme.fontFamily : "sans-serif"
        fontSize: Style.font.body
        width: root.vertical ? root.barSize : implicitWidth
        consumesWheel: root.vertical
        onWheelMoved: function(delta) { root.scrollPills(delta); }
        onToggled: { root.close(); root.service.toggleScratchpad(root.monitorName); }
        onMenuRequested: function(position) {
          root.readFollowState();
          root.ui.explicitOpen(root, scratchpadPill, "special:scratchpad", "menu");
          menu.selectedIndex = 0;
        }
      }
    }
  }
  WidgetButton {
    id: toggleButton
    anchors.right: parent.right
    anchors.top: root.vertical ? workspaceScroll.bottom : undefined
    bar: root.bar
    fixedHeight: root.vertical ? root.barSize : -1
    text: "▥"
    tooltipText: "Paperland minimap"
    onPressed: function(button) {
      if (button !== Qt.LeftButton) return;
      root.toggleRequests += 1;
      if (!toggleProcess.running) toggleProcess.running = true;
    }
  }
  Process { id: toggleProcess; command: [root.executable, "toggle"] }
  Process { id: settingsProcess; command: [root.executable, "settings"] }

  PopupCard {
    id: preview
    bar: root.bar
    owner: passiveOwner
    anchorItem: root.ownsUi && root.ui.anchor ? root.ui.anchor : root
    triggerMode: "hover"
    open: root.ownsUi && root.ui.mode === "hover" && !!root.currentEntry
    contentWidth: PreviewGeometry.popupExtent(passivePreview.items.length ? passivePreview.desiredWidth + padding * 2 + Border.left(borderSpec) + Border.right(borderSpec) : 360,
      passivePreview.items.length ? 720 : 360, availableCardWidth)
    contentHeight: PreviewGeometry.popupExtent(passivePreview.items.length ? passivePreview.desiredHeight + verticalContentInset : 180,
      passivePreview.items.length ? 480 : 180, availableCardHeight)
    // PopupCard remains mapped during its fade. Remove the dying input region
    // immediately so the application beneath it can receive pointer input.
    mask: Region { width: preview.open ? preview.width : 0; height: preview.open ? preview.height : 0 }
    onContainsMouseChanged: if (root.ownsUi) root.ui.card(containsMouse)
    Shared.WorkspacePreview {
      id: passivePreview
      highlightAddress: root.pillHighlight
      spacious: true
      anchors.fill: parent
      thumbnailSource: Qt.resolvedUrl("paperland/native/WindowThumbnail.qml")
      externalControl: Native.PreviewControl.pressed
      captureEnabled: preview.visible
      iconFor: Native.Runtime.iconFor
      nameFor: Native.Runtime.nameFor
      entry: root.currentEntry
      row: root.previewRow(root.currentEntry)
      badgeAddresses: root.service.stripBadgeAddresses
      urgentAddresses: root.service.urgentAddresses
      focusedAddress: root.service.focusedAddress
      onActivated: function(address) { root.activate(address); }
      onWindowMenuRequested: function(address, position) { root.openPreviewMenu(address, position, passivePreview); }
    }
  }
  Connections {
    target: root.service
    function onRemovalFinished(outcome) {
      if (!root.ownsUi || root.ui.mode !== "remove") return;
      removeCard.showResult(outcome);
      // The moves and landing focus other windows, so the OnDemand panel loses the keyboard; prime it again.
      panel.focusPrimed = false;
      panel.beginFocusPrime();
    }
  }
  KeyboardPanel {
    id: panel
    bar: root.bar
    owner: explicitOwner
    anchorItem: root.ownsUi && root.ui.anchor ? root.ui.anchor : root
    open: root.explicitUi && (root.ui.mode === "quick" || root.ui.mode === "remove" || !!root.currentEntry)
    WlrLayershell.keyboardFocus: Native.Runtime.sendMenu.opened || !panel.open ? WlrKeyboardFocus.None
      : panel.focusPrimed ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive
    mask: Region { width: panel.open && !Native.Runtime.sendMenu.opened ? panel.width : 0; height: panel.open && !Native.Runtime.sendMenu.opened ? panel.height : 0 }
    contentWidth: root.ui.mode === "quick" ? panel.fittedContentWidth(280)
      : panel.fittedContentWidth(500)
    contentHeight: root.ui.mode === "quick" ? panel.fittedContentHeight(quickMenu.implicitHeight)
      : root.ui.mode === "remove" ? panel.fittedContentHeight(removeCard.implicitHeight)
      // The menu's rows plus the panel's own padding; the bare row height clipped the last rows.
      : root.ui.mode === "menu" ? panel.fittedContentHeight(Math.max(220, menu.implicitHeight))
      : panel.cappedContentHeight(root.ui.mode === "windows" ? 420 : root.ui.mode === "close" ? closeConfirm.implicitHeight : 310)
    focusTarget: root.ui.mode === "quick" ? quickMenu : root.ui.mode === "rename" ? editor : root.ui.mode === "windows" ? explicitPreview : root.ui.mode === "close" ? closeConfirm : root.ui.mode === "remove" ? removeCard : menu
    Shared.QuickMenu {
      id: quickMenu
      anchors.fill: parent
      visible: root.ui.mode === "quick"
      status: root.quickStatus
      runtimeState: root.quickRuntime
      error: root.quickError
      pending: root.quickPending
      alert: root.quickAlert
      centering: root.quickCentering
      centeringError: root.quickCenteringError
      foreground: Color.popups.text
      background: Color.popups.background
      accent: Color.accent
      accentInk: Paper.Theme.accentInk(Color.accent)
      urgent: Color.urgent
      tooltipBackground: Color.tooltip.background
      tooltipForeground: Color.tooltip.text
      tooltipBorder: Color.tooltip.border
      fontFamily: root.barTheme ? root.barTheme.fontFamily : Style.font.family
      fontSize: Style.font.body
      onCancelled: root.close()
      onChosen: function(action) { root.chooseQuick(action); }
    }
    Shared.WorkspaceMenu {
      id: menu
      anchors.fill: parent
      visible: root.ui.mode === "menu"
      entry: root.currentEntry
      allEntries: root.service.allEntries()
      foreground: Color.popups.text
      highlightFill: Qt.alpha(Color.popups.text, 0.14)
      followChecked: root.followChecked
      settingsAvailable: true
      onCancelled: root.close()
      onChosen: function(action) {
        if (action === "windows") root.ui.mode = "windows";
        else if (action === "rename") root.rename(false);
        else if (action === "clear") root.rename(true);
        else if (action === "follow") { root.toggleFollow(); root.close(); }
        else if (action === "settings") { root.close(); if (!settingsProcess.running) settingsProcess.running = true; }
        else if (action === "close") { root.ui.mode = "close"; closeConfirm.begin(root.currentEntry.id, menu.closable); }
        else if (action === "remove") { root.ui.mode = "remove"; removeCard.begin(root.currentEntry, root.service.allEntries(), root.service.destinations); }
      else if (root.currentEntry && !root.currentEntry.special) { var id = root.currentEntry.id; root.close(); root.service.activateWorkspace(id); }
      }
    }
    Shared.WorkspacePreview {
      id: explicitPreview
      anchors.fill: parent
      visible: root.ui.mode === "windows"
      thumbnailSource: Qt.resolvedUrl("paperland/native/WindowThumbnail.qml")
      captureEnabled: panel.visible && root.ui.mode === "windows"
      iconFor: Native.Runtime.iconFor
      nameFor: Native.Runtime.nameFor
      entry: root.currentEntry
      row: root.previewRow(root.currentEntry)
      badgeAddresses: root.service.stripBadgeAddresses
      urgentAddresses: root.service.urgentAddresses
      focusedAddress: root.service.focusedAddress
      keyboardMode: true
      onActivated: function(address) { root.activate(address); }
      onWindowMenuRequested: function(address, position) { Native.Runtime.sendMenu.openFor(address, root.ownWindow.screen, position, root.barSlab()); }
      onCancelled: root.close()
    }
    Shared.WorkspaceCloseConfirm {
      id: closeConfirm
      anchors.fill: parent
      visible: root.ui.mode === "close"
      onCancelled: root.close()
      onConfirmed: function(id, targets) { root.close(); root.service.closeWindows(id, targets); }
    }
    Shared.DesktopRemoveCard {
      id: removeCard
      objectName: "desktop-remove-card"
      anchors.fill: parent
      visible: root.ui.mode === "remove"
      foreground: Color.popups.text
      accent: Color.accent
      accentInk: Paper.Theme.accentInk(Color.accent)
      onCancelled: root.close()
      onConfirmed: run(root.service)
      onRetryRequested: {
        var current = root.service.catalog.entries[source];
        if (current) retry(current, root.service.allEntries(), root.service.destinations); else root.close();
      }
    }
    Shared.WorkspaceEditor {
      id: editor
      anchors.fill: parent
      visible: root.ui.mode === "rename"
      client: Native.Runtime.names
      onCancelled: root.close()
    }
  }
}
