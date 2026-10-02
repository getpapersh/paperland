import QtQuick
import "paperland/shared/PreviewGeometry.js" as PreviewGeometry
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
  readonly property bool explicitUi: ownsUi && ["menu", "rename", "windows", "quick", "close"].indexOf(ui.mode) >= 0
  implicitWidth: Math.min(Number(setting("maxWidth", 640)), menuButton.implicitWidth + workspaceRow.implicitWidth + toggleButton.implicitWidth)
  implicitHeight: barSize
  onEntriesChanged: {
    var ids = entries.map(function(e) { return e.id; });
    if (JSON.stringify(ids) !== JSON.stringify(itemIds)) itemIds = ids;
    // The quick menu belongs to no Desktop, so Desktop changes never close it.
    if (ownsUi && !currentEntry && ui.mode !== "quick") close();
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
  QtObject { id: explicitOwner; function close() { root.close(); } }
  function openPreviewMenu(address: string, position: point, source: Item): void {
    // Qt includes the popup offset but omits its root layer's placement.
    var global = source.mapToGlobal(0, 0), scene = source.mapToItem(null, 0, 0);
    var base = root.ownWindow.contentItem.mapToGlobal(0, 0);
    var window = root.ownWindow, screen = window.screen;
    var x = window.anchors.left ? window.margins.left : screen.width - window.width - window.margins.right;
    var y = window.anchors.top ? window.margins.top : screen.height - window.height - window.margins.bottom;
    Native.Runtime.sendMenu.openFor(address, screen, Qt.point(position.x + global.x - scene.x - base.x + x,
      position.y + global.y - scene.y - base.y + y));
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
    ui.explicitOpen(root, button, entry.id, "menu");
    menu.selectedIndex = 0;
  }
  function openFocused() { if (entries.some(function(e) { return e.focused; })) open(); }
  function snapshot() {
    return { monitor: monitorName, mode: ownsUi ? ui.mode : "", workspace: ownsUi ? ui.workspace : 0,
      previewZoom: passivePreview.mapZoom, previewOpen: preview.open, editorOpen: panel.open && ui.mode === "rename",
      nameBusy: Native.Runtime.names.busy, nameMessage: Native.Runtime.names.message, nameRequest: Native.Runtime.names.requestId,
      editorCaptureId: editor.draftCapture ? editor.draftCapture.id : 0,
      activationError: service.activationError,
      foreignPopout: !!bar.activePopout && bar.activePopout !== passiveOwner && bar.activePopout !== explicitOwner,
      popup: { x: preview.anchor.rect.x, y: preview.anchor.rect.y, width: preview.width, height: preview.height },
      items: itemIds.map(function(id, index) {
        var button = workspaceRepeater.itemAt(index);
        var point = button && root.ownWindow ? root.ownWindow.itemPosition(button) : Qt.point(0, 0);
        return { id: id, entry: root.entryFor(id), x: point.x, y: point.y, width: button ? button.width : 0, height: button ? button.height : 0 };
      }), scratchpad: { visible: scratchpadPill.visible, entry: scratchpadPill.entry,
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
  }
  function toggle() { if (explicitUi) close(); else open(); }
  function rename(clearing) {
    if (!currentEntry) return;
    ui.mode = "rename";
    editor.begin(currentEntry.id, currentEntry.name, clearing);
  }
  function activate(address) { activation.address = address; close(); activation.restart(); }
  Timer { id: activation; property string address: ""; interval: 40; onTriggered: service.activate(address) }
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
    function onActivePopoutChanged() { if (root.ownsUi && root.ui.opened && root.bar.activePopout && root.bar.activePopout !== passiveOwner && root.bar.activePopout !== explicitOwner) root.close(); }
  }
  Binding {
    target: Native.Runtime.names
    property: "executable"
    value: root.executable
  }
  Component.onDestruction: { if (ownsUi) ui.close(); }

  Paper.ActivationNotice { service: root.service; noticeScreen: root.ownWindow ? root.ownWindow.screen : null; eligible: root.entries.some(function(entry) { return entry.focused; }) }

  WidgetButton {
    id: menuButton
    objectName: "paperland-menu-button"
    anchors.left: parent.left
    bar: root.bar
    hasVisualContent: true
    labelVisible: false
    fixedWidth: 16 + scaledHorizontalMargin * 2
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
    anchors.left: menuButton.right
    width: Math.max(0, root.width - menuButton.width - toggleButton.width)
    height: parent.height
    contentWidth: workspaceRow.implicitWidth
    contentHeight: height
    flickableDirection: Flickable.HorizontalFlick
    clip: true
    Row {
      id: workspaceRow
      Repeater {
        id: workspaceRepeater
        model: root.itemIds
        delegate: WidgetButton {
          id: workspaceButton
          required property int modelData
          readonly property var entry: root.entryFor(modelData)
          objectName: "paperland-workspace-" + modelData
          bar: root.bar
          hasVisualContent: true
          labelVisible: false
          fixedWidth: label.implicitWidth + 18
          dimmed: !entry || (!entry.active && entry.count === 0)
          tooltipText: ""
          Accessible.role: Accessible.Button
          Accessible.name: label.accessibleName
          Accessible.onPressAction: triggerPress(Qt.LeftButton)
          onTooltipHoveredChanged: {
            if (tooltipHovered && entry) root.ui.enter(root, workspaceButton, modelData);
            else root.ui.leave(root, workspaceButton);
          }
          onPressed: function(button) {
            if (!entry) return;
            if (button === Qt.LeftButton) { root.close(); root.service.activateWorkspace(modelData); }
            else if (button === Qt.RightButton) {
              menu.selectedIndex = 0;
              root.ui.explicitOpen(root, workspaceButton, modelData, "menu");
            }
          }
          // The scratchpad-open treatment shared with the minimap: the active
          // desktop pill fades beneath a dashed accent outline. The fade sits
          // on the visual children because WidgetButton owns its own opacity.
          Item {
            id: pillVisual
            readonly property bool scratchpadShown: workspaceButton.entry && workspaceButton.entry.active
              && root.scratchpadEnabled && root.scratchpadEntry.active
            anchors.fill: parent
            opacity: pillVisual.scratchpadShown ? 0.55 : 1
            Rectangle {
              anchors.centerIn: parent
              width: parent.width - 4
              height: Math.min(parent.height - 6, 26)
              radius: height / 2
              color: workspaceButton.entry && workspaceButton.entry.active ? "#a55eab" : "transparent"
              // The dashed outline replaces this border while the scratchpad
              // is open, as on the minimap's faded pill.
              border.width: workspaceButton.entry && workspaceButton.entry.focused
                && !pillVisual.scratchpadShown ? 1 : 0
              border.color: "#e4b0e8"
            }
            // A sibling bound to the highlight rectangle's exact geometry, not
            // a child of it: the outline must trace the pill's real edge inside
            // the bar's scene, where nesting it distorted the path.
            Shared.ScratchpadOutline {
              anchors.centerIn: parent
              width: parent.width - 4
              height: Math.min(parent.height - 6, 26)
              visible: pillVisual.scratchpadShown
            }
            Shared.WorkspaceLabel {
              id: label
              anchors.centerIn: parent
              width: implicitWidth
              entry: workspaceButton.entry
              foreground: entry && entry.active ? "white" : workspaceButton.foreground
              fontFamily: workspaceButton.fontFamily
              fontSize: Style.font.body
            }
          }
        }
      }
      Shared.ScratchpadPill {
        id: scratchpadPill
        objectName: "paperland-scratchpad"
        barStyle: true
        barHeight: root.barSize
        pillEnabled: root.scratchpadEnabled
        showName: true
        entry: root.scratchpadEntry
        shortcutBinding: root.service.scratchpadBinding
        open: root.scratchpadEntry.active
        foreground: root.barTheme ? root.barTheme.barForeground : "#dddddd"
        fontFamily: root.barTheme ? root.barTheme.fontFamily : "sans-serif"
        fontSize: Style.font.body
        width: implicitWidth
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
    bar: root.bar
    text: "▥"
    tooltipText: "Paperland minimap"
    onPressed: function(button) { if (button === Qt.LeftButton && !toggleProcess.running) toggleProcess.running = true; }
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
      focusedAddress: root.service.focusedAddress
      onActivated: function(address) { root.activate(address); }
      onWindowMenuRequested: function(address, position) { root.openPreviewMenu(address, position, passivePreview); }
    }
  }
  KeyboardPanel {
    id: panel
    bar: root.bar
    owner: explicitOwner
    anchorItem: root.ownsUi && root.ui.anchor ? root.ui.anchor : root
    open: root.explicitUi && (root.ui.mode === "quick" || !!root.currentEntry)
    WlrLayershell.keyboardFocus: Native.Runtime.sendMenu.opened || !panel.open ? WlrKeyboardFocus.None
      : panel.focusPrimed ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive
    mask: Region { width: panel.open && !Native.Runtime.sendMenu.opened ? panel.width : 0; height: panel.open && !Native.Runtime.sendMenu.opened ? panel.height : 0 }
    contentWidth: root.ui.mode === "quick" ? panel.fittedContentWidth(280)
      : Math.min(500, root.ownWindow && root.ownWindow.screen ? root.ownWindow.screen.width - 32 : 500)
    contentHeight: root.ui.mode === "quick" ? panel.fittedContentHeight(quickMenu.implicitHeight)
      : Math.min(root.ui.mode === "menu" ? Math.max(220, menu.implicitHeight) : root.ui.mode === "windows" ? 420 : root.ui.mode === "close" ? closeConfirm.implicitHeight : 310, root.ownWindow && root.ownWindow.screen ? root.ownWindow.screen.height - 32 : 420)
    focusTarget: root.ui.mode === "quick" ? quickMenu : root.ui.mode === "rename" ? editor : root.ui.mode === "windows" ? explicitPreview : root.ui.mode === "close" ? closeConfirm : menu
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
      focusedAddress: root.service.focusedAddress
      keyboardMode: true
      onActivated: function(address) { root.activate(address); }
      onWindowMenuRequested: function(address, position) { Native.Runtime.sendMenu.openFor(address, root.ownWindow.screen, position); }
      onCancelled: root.close()
    }
    Shared.WorkspaceCloseConfirm {
      id: closeConfirm
      anchors.fill: parent
      visible: root.ui.mode === "close"
      onCancelled: root.close()
      onConfirmed: function(id, targets) { root.close(); root.service.closeWindows(id, targets); }
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
